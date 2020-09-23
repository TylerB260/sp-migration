param (
    $migration = -1,
    $file = ""
)

#Remove-Item -Path ".\error.log"

###################################################
# Do not change anything below this line. Thanks! #
###################################################
  
$old_url = "https://onpremise.hurleynet.us"
$new_url = "https://exampletennant.sharepoint.com"

Set-Location $PSScriptRoot

. .\modules\utility.ps1
. .\modules\files.ps1

$migrations = @();
$global:old_context = $null
$global:new_context = $null

$old_site = "" # source site on the $old_url variable
$new_site = ""  # destination site on the $new_url variable.

$old_library = "" # source document library on the $old_url variable
$new_library = ""  # destination document library on the $new_url variable.

$host.ui.RawUI.WindowTitle = "SharePoint Migration - Starting..."

function Start-Migration(){
    param(
        $migration = -1,
        $file = ""
    )

    # doesn't work for some reason... annoying.
    #$path = ((Split-Path $myInvocation.MyCommand.Path) + "\" + $MyInvocation.MyCommand.Name)
    $path = "$PSScriptRoot\new-copy.ps1"

    $child = Start-Process powershell -NoNewWindow -Wait -PassThru -ArgumentList $path, "-migration $migration -file $file" -RedirectStandardError "error.log"

    if($child.ExitCode -eq 2426){
        Start-Migration -migration $migration # start it over again so we can get a new session.
    }elseif($child.ExitCode -ne 0){
        Write-Host "Halting further migrations due to exit code of last child process: $($child.ExitCode)."
        exit
    }
}

Import-Module SharePointPnPPowerShell2016
[System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SharePoint.Client")
[System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SharePoint.Client.Runtime")

############################################################################################
# this block gets called if we are running the script itself. it calls the child processes #
############################################################################################

$old_items = @{}
$new_items = @{}

if($migration -eq -1){
    $host.ui.RawUI.WindowTitle = "SharePoint Migration & Synchronization Client by Tyler B."
    
    $files = Get-ChildItem -Path "migrations" | where {!$_.PSIsContainer}

    for($i = 0; $i -lt $files.Count; $i++){
        Write-Host "$($i + 1). $($files[$i].Name)"
    }

    $opt = 999
    
    while($files[$opt - 1] -eq $null){
        $opt = [int](Read-Host "Choose Migration")
    }
    
    $file = $files[$opt - 1]

    . .\migrations\$file

    for($migration = 0; $migration -lt $migrations.Count; $migration++){
        Start-Migration -migration $migration -file $file
    }

    Write-Host "Finished!"
	Read-Host "Press enter to continue."
}else{
    #######################################################
    # this block gets called when we are a child process. #
    #######################################################
    
    Write-Host "File: $file"
    . .\migrations\$file
    
    $migration = $migrations[$migration]

    $folders_skipped = 0
    $folders_copied = 0
    $folders_deleted = 0
    $folders_errored = 0

    $files_skipped = 0
    $files_copied = 0
    $files_deleted = 0
    $files_errored = 0

    $errors = @()
    $deleted = @()

    $old_site = $migration.old_site
    $new_site = $migration.new_site

    ###########################################################################
    # Connect to SharePoint OnPrem and SharePoint Online for File Operations. #
    ###########################################################################
    
    Util-ConnectOldSharePoint

    foreach($old_library in $migration.libraries.Keys){
        $new_libraries = @{}

        $old_list = Get-PnPList -Identity $old_library
        $EnableVersioning = !($old_list.EnableVersioning -eq $false)
        
        $temp = $migration.libraries[$old_library]

        if($temp -is [string]){
            $new_libraries[$temp] = {return $true}
        }else{
            $new_libraries = $temp
        }

        foreach($new_library in $new_libraries.Keys){
            $global:user_cache = @{};
            $filter_function = $new_libraries[$new_library]

            Util-ConnectNewSharePoint
        
            $host.ui.RawUI.WindowTitle = "Starting Migration - $old_site/$old_library --> $new_site/$new_library"
    
            Write-Host ""
            Write-host "Grabbing directory listings and beginning synchronization..."
            Write-Host "Source:      $old_url/$old_site/$old_library"
            Write-Host "Destination: $new_url/$new_site/$new_library"
            Write-Host ""
             
            $old_items = @{}
            $new_items = @{}

            # grab the file list from onprem and build a hashtable.
            Write-Host "Grabbing directory listing from SharePoint OnPrem..."
            foreach($item in (File-GrabList -context $global:old_context -library $old_library)){
                $old_items[$item.FieldValues.FileRef.Replace((Util-FixPath "/$old_site/$old_library/"), "")] = $item
            }


            # grab the online directory listing.
            Write-Host "Grabbing directory listing from SharePoint Online..."
            foreach($item in (File-GrabList -context $global:new_context -library $new_library)){
                $new_items[$item.FieldValues.FileRef.Replace((Util-FixPath "/$new_site/$new_library/"), "")] = $item
            }

            # build a list of objects to delete.
            $delete_items = $new_items;
            $i = 0

            foreach($relative_path in $old_items.Keys){
                $old_item = $old_items[$relative_path]
                $new_item = $new_items[$relative_path]
            
                $i++
                $percent = [math]::floor(($i / $old_items.Count) * 100)

                $host.ui.RawUI.WindowTitle = "Migrating ($percent%, $i of $($old_items.Count)) $old_site/$old_library --> $new_site/$new_library"
               
                $result = Util-DetermineValues -old_item $old_item -new_item $new_item -EnableVersioning $EnableVersioning
                
                # does this meet our filter requirements?
                if($filter_function.Invoke($old_item)){
                    
                    # remove this item from the delete list since it's present on source.
                    $delete_items.Remove($relative_path)
                
                    # item is missing on destination
                    if($new_item -eq $null){

                        # is it a file?
                        if($old_item.FieldValues.File_x0020_Size -ne ""){
                            Write-Host "Copying MISSING file: $relative_path"
                            $files_copied++

                            File-Transfer -Path $relative_path -Values $result.Values -EnableVersioning $EnableVersioning

                        # is it a folder?
                        }else{
                            Write-Host "Creating MISSING folder: $relative_path"
                            $folders_copied++

                            Util-ChangeContext $global:new_context

                            Resolve-PnPFolder -SiteRelativePath "$new_library/$relative_path" | Out-Null
                            File-UpdateFolder -Path $relative_path -Values $result.Values
                        }

                    # item exists on destination already
                    }else{

                        # check to see if columns differ - if they do, then copy the new file over.
                        if($result.Modified){
                            # is it a file?
                            if($old_item.FieldValues.File_x0020_Size -ne ""){
                                Write-Host "Updating MODIFIED file: $relative_path"
                                $files_copied++

                                File-Transfer -Path $relative_path -Values $result.Values -EnableVersioning $EnableVersioning

                            # is it a folder?
                            }else{
                                Write-Host "Updating MODIFIED folder: $relative_path"
                                $folders_copied++

                                File-UpdateFolder -Path $relative_path -Values $result.Values
                            }
                        }else{
                            if($old_item.FieldValues.File_x0020_Size -ne ""){
                                Write-Host "Skipping file: $relative_path"
                                $files_skipped++
                            }else{
                                Write-Host "Skipping folder: $relative_path"
                                $folders_skipped++
                            }
                        }
                    }
                }else{
                    if($old_item.FieldValues.File_x0020_Size -ne ""){
                        Write-Host "Skipping FILTERED file: $relative_path"
                        #$files_skipped++
                    }else{
                        Write-Host "Skipping FILTERED folder: $relative_path"
                        #$folders_skipped++
                    }
                }
            }

            foreach($relative_path in $delete_items.Keys){
                $delete_item = $delete_items[$relative_path]

                # is it a file?
                if($delete_item.FieldValues.File_x0020_Size -ne ""){
                    Write-Host "Removing DELETED file: $relative_path"
                    $files_deleted++

                    $temp_context = Get-PnPContext

                    Util-ChangeContext $global:new_context
                    Remove-PnPFile -SiteRelativeUrl "$new_library/$relative_path" -Recycle -Force
                # is it a folder?
                }else{
                    Write-Host "Removing DELETED folder: $relative_path"
                    $folders_deleted++

                    $temp_context = Get-PnPContext

                    $name = Split-Path -Path $relative_path -Leaf
                    $path = Split-Path -Path $relative_path
                 
                    Util-ChangeContext $global:new_context
                    Remove-PnPFolder -Name $name -Folder "$new_library/$path" -Recycle -Force
                }
            }
        }
    }

    #####################################
    # Show statistics for the transfer. #
    #####################################

    $stats = @(
        @{Name = "Files"; Copied = $files_copied; Skipped = $files_skipped; Deleted = $files_deleted; Errored = $files_errored};
        @{Name = "Folders"; Copied = $folders_copied; Skipped = $folders_skipped; Deleted = $folders_deleted; Errored = $folders_errored};
    )

    $stats | ForEach {[PSCustomObject]$_} | Format-Table -Property Name, Copied, Skipped, Deleted, Errored

    if($errors.Count -gt 0){
        Write-Host ""
        Write-Host "Errors:"

        $errors | ForEach {
            Write-Host " - $_" -ForegroundColor Red
        }
    }

    if($deleted.Count -gt 0){
        Write-Host ""
        Write-Host "Deleted Files/Folders:"

        $deleted | ForEach {
            Write-Host " - $_" -ForegroundColor Green
        }
    }

    Start-sleep -Seconds 5
}  