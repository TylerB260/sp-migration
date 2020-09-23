function File-GrabList(){
    param(
        $context = (Get-PnPContext),
        $library
    )

    $split = $library.Split("/")

    #$list = Get-PnPList -Identity $split[0]
    
    $list = $context.Web.GetList("$($context.Url)/$($library.Split("/")[0])")
    
    $items = [System.Collections.ArrayList]@()
    
    $query = New-Object Microsoft.SharePoint.Client.CamlQuery
    $query.ViewXml = "
        <View Scope='RecursiveAll'>
            <RowLimit>500</RowLimit>
        </View>
    "
   
    do {
        $temp = $list.GetItems($query)
        $context.Load($temp)
        $context.ExecuteQuery()

        foreach($item in $temp){
            $items+=$item
        }

        $query.ListItemCollectionPosition = $temp.ListItemCollectionPosition
    } while($query.ListItemCollectionPosition -ne $null)

    # subfolder, for consultant site migrations.
    if($split.Count -gt 1){
        $new_items = [System.Collections.ArrayList]@()

        $path = "/$(Split-Path -Path $context.Url -Leaf)/$library/"

        foreach($item in $items){
            if($item.FieldValues.FileRef.StartsWith($path) -or $item.FieldValues.FileRef.StartsWith("/sites$path")){
                $new_items+=$item
            }
        }

        return $new_items
    }

    return $items
}

function File-UpdateFolder(){
    param(
        $Path, # relative path
        $Values
    )

    $relative_path = (Util-FixPath -path "$new_library/$Path")
    
    # grab folder #
    $folder = Get-PnPFolder -Url $relative_path
    $item = $folder.ListItemAllFields
    
    $global:new_context.Load($folder)
    $global:new_context.Load($item)
    $global:new_context.ExecuteQuery()

    # update folder #
    $Values.Keys | foreach {
        $item[$_] = $Values[$_]
    }
            
    $item.Update()
    $global:new_context.ExecuteQuery()
}

function File-EnsureDir(){
    param(
        $Path
    )
        
    $todo =  @($Path)

    function recurse(){
        param(
            $Path,
            $temp = @()
        )

        if(($Path -eq $null) -or ($Path -eq "")){return $temp}
        $next = (Split-Path -Path $Path)

        if($next -eq ""){return $temp}
        $temp += $next

        recurse -Path $next -temp $temp
    }

    $todo = recurse -Path $Path -temp $todo

    for($i = $todo.Count - 1; $i -ge 0; $i--){
        Write-Host "------------------------------"
        Write-Host "------------------------------"
        
        $curpath = $todo[$i]

        $exists = Get-PnPFolder -Url $curpath -ErrorAction SilentlyContinue
        
        Write-Host $curpath

        if($exists){
            Write-Host "Folder already exists. Skipping."
        }else{
            Write-Host "Creating folder as it does not exist."

            Write-Host $curpath
            Write-Host (Split-Path -Path $curpath -Leaf)
            Write-Host (Split-Path -Path $curpath)

            Add-PnPFolder -Name (Split-Path -Path $curpath -Leaf) -Folder (Split-Path -Path $curpath) | Out-Null
        }
    }
}

function File-Transfer(){
    param(
        $Path, # relative path
        $Values,
        $EnableVersioning = $true
    )

    $old_path = (Util-FixPath -path "/$old_site/$old_library/$Path")
    $new_path = (Util-FixPath -path "/$new_site/$new_library/$Path")
    
    Util-ChangeContext $global:old_context
    $old_item = Get-PnPFile -Url $old_path -AsListItem
    if(!$old_item){Util-HandleError "The source file is missing. ($old_path)"}
    
    $old_item = $null
    $new_item = $null
    
    if($old_items -and ($old_items[$Path] -ne $null)){
        $old_item = $old_items[$Path]
    }else{
        Util-ChangeContext $global:old_context
        $old_item = Get-PnPFile -Url $old_path -AsListItem -ErrorAction SilentlyContinue
    }

    if($new_items -and ($new_items[$Path] -ne $null)){
        $new_item = $new_items[$Path]
    }else{
        Util-ChangeContext $global:new_context
        $new_item = Get-PnPFile -Url $new_path -AsListItem -ErrorAction SilentlyContinue
    }

    # for use later.
    $old_versions = @()
    $new_versions = @()
    $start = -1

    if($EnableVersioning){
        $old_versions = $old_item.File.Versions
        $global:old_context.Load($old_versions)
        $global:old_context.ExecuteQuery()
        
        $old_versions += @{
            "Created" = $old_item.FieldValues.Modified; # IMPORTANT!!!! CREATED IS THE TIME THE VERSION WAS CREATED, NOT THE FILE! *facepalm*
            "CreatedBy" = $old_item.FieldValues.Author;
            "VersionLabel" = $old_item.FieldValues._UIVersionString;
            "CheckInComment" = $old_item.FieldValues._CheckinComment;
            "IsCurrentVersion" = $true;
        }

        if(!$new_item){
            # no new file - we will go ahead and upload the entire shebang.
            $start = 0
        }else{
            $new_versions = $new_item.File.Versions
            $global:new_context.Load($new_versions)
            $global:new_context.ExecuteQuery()

            # add the current versions as a version #
            $new_versions += @{
                "Created" = $new_item.FieldValues.Modified;
                "CreatedBy" = $new_item.FieldValues.Author;
                "VersionLabel" = $new_item.FieldValues._UIVersionString;
                "CheckInComment" = $new_item.FieldValues._CheckinComment;
                "IsCurrentVersion" = $true;
            }

            if([float]$old_item.FieldValues._UIVersionString -lt [float]$new_item.FieldValues._UIVersionString){
                # the new file has more versions that the old, something is wrong. scrap the entire thing.
                $start = 0
            }else{
                # loop through both version histories and compare #

                for($i = 0; $i -lt $old_versions.Count; $i++){
                    $old_version = $old_versions[$i]
                    $new_version = $new_versions[$i]
                
                    #$old_version | Format-Table
                    #$new_version | Format-Table
                    #Write-Host ""

                    $break = $false

                    if(!$new_version){
                        # this version is missing, let's add it and following versions.
                        Write-Host " - Version $($old_version.VersionLabel) is missing! Uploading all following versions."
                        $start = $i
                         $break = $true

                    }elseif($old_version.Created.ToUniversalTime() -ne $new_version.Created.ToUniversalTime()){
                        # scrap it all. we can't modify versions, only add versions.
                        Write-Host " - Version $($old_version.VersionLabel)'s timestamps do NOT match. Someone modified the file on 365!"

                        #Write-Host "$($old_version.VersionLabel) vs. $($new_version.VersionLabel)"
                        #Write-Host "$($old_version.Created.ToUniversalTime()) vs. $($new_version.Created.ToUniversalTime())"
                        #Read-Host "waiting..."

                        $start = 0
                        $break = $true

                    }elseif($old_version.CheckInComment -ne $new_version.CheckInComment){
                        # scrap it all. we can't modify versions, only add versions.
                        Write-Host " - Version $($old_version.VersionLabel)'s comments do NOT match. Someone modified the file on 365!"

                        #Read-Host "waiting..."

                        #$start = 0
                        #$break = $true
                    }

                    if($break){break}
                }

                #Write-Host "finished scanning"
            }
        }
    }else{
        $start = 0

        $old_versions += @{
            "Created" = $old_item.FieldValues.Modified;
            "CreatedBy" = $old_item.FieldValues.Author;
            "VersionLabel" = $old_item.FieldValues._UIVersionString;
            "CheckInComment" = $old_item.FieldValues._CheckinComment;
            "IsCurrentVersion" = $true;
        }

        $new_versions += @{
            "Created" = $new_item.FieldValues.Modified;
            "CreatedBy" = $new_item.FieldValues.Author;
            "VersionLabel" = $new_item.FieldValues._UIVersionString;
            "CheckInComment" = $new_item.FieldValues._CheckinComment;
            "IsCurrentVersion" = $true;
        }
    }

    # the actual logic of the function #

    #Write-Host "Result: $start"
    #Read-Host "Waiting..."

    if($start -eq -1){
        Write-Host " - False alarm! A previous version was deleted - skipping file."
        return

    }elseif($start -eq 0){ # there's only one version. delete the file and start again.
        #Write-Host "online version is newer than old version - scrap it and redo."
        Util-ChangeContext $global:new_context
        Remove-PnPFile -ServerRelativeUrl $new_path -Force -Recycle
    }

    # Ensure directory we're writing to exists.
    Util-ChangeContext $global:new_context

    #File-EnsureDir -Path (Split-Path -Path "$new_library/$Path") | Out-Null
    Resolve-PnPFolder -SiteRelativePath (Split-Path -Path "$new_library/$Path") | Out-Null

    Util-ChangeContext $global:old_context

    #Read-Host "Paused Uploading."

    for($i = $start; $i -lt $old_versions.Count; $i++){
        # grab the version from old context and upload it to the new context
        $old_version = $old_versions[$i]
        $new_version = $new_versions[$i]

        Write-Host " - Uploading version $($old_version.VersionLabel) of file $new_path"
        
        $attempt = 1
        $success = $false
        
        $setmeta = {
            param(
                $file
            )
            
            try {
                if($old_version.CheckInComment -ne ""){
                    $file.CheckOut()
                    $file.CheckIn($old_version.CheckInComment, [Microsoft.SharePoint.Client.CheckinType]::OverwriteCheckIn)
                }
                
                $item = $file.ListItemAllFields
                $global:new_context.Load($item)
                $global:new_context.ExecuteQuery()
                
                $meta = @{}

                if($old_version.IsCurrentVersion){
                    $meta = $Values
                }else{
                    $global:old_context.Load($old_version.CreatedBy)
                    $global:old_context.ExecuteQuery()
                    
                    $meta = @{ # need each of these or SP goes apeshit. spent way too long figuring this out.
                        Author = (Util-GrabUser -context $global:old_context -id $old_version.CreatedBy.Id);
                        Editor = (Util-GrabUser -context $global:old_context -id $old_version.CreatedBy.Id);
                        Created = $old_version.Created;
                        Modified = $old_version.Created;
                    }
                }

                $meta.Keys | foreach {
                    $item[$_] = $meta[$_]
                }

                $item.UpdateOverwriteVersion()
                $global:new_context.ExecuteQuery()
            } catch {
                Write-Host $($_.Exception.Message)
                Write-Host $($_.Exception.StackTrace)
                Write-Host "Setting metadata failed. Waiting 5 seconds and trying again..."
                Start-Sleep -Seconds 5
                $setmeta.Invoke($file)
            }
        }

        $upload = {
            # over 1Gb - just give up and make the user do it. SP online is too damn slow and times out.
            if([int]$old_item.FieldValues.File_x0020_Size -gt 1048576000){
                Write-Host "File size is WAY too large! ($($old_item.FieldValues.File_x0020_Size))."
                return $false
            }

            $file = $null
            $stream = $null

            if($old_version.IsCurrentVersion){
                # copy over all of the metadata, this is the final file. #
                $stream = $old_item.File.OpenBinaryStream()
            }else{
                $stream = $old_version.OpenBinaryStream()
            }

            if(!$stream){Util-HandleError "Something went wrong - our stream is null. Failed to upload file."}

            $global:old_context.ExecuteQuery()
            $stream = $stream.Value
        
            Util-ChangeContext $global:new_context
            
            if([int]$old_item.FieldValues.File_x0020_Size -gt 262144000){
                $global:new_context.ExecuteQuery() # just in case?  
                
                $file = [Microsoft.SharePoint.Client.File]
                $file::SaveBinaryDirect($global:new_context, $new_path, $stream, $true)

                $file = $global:new_context.Web.GetFileByServerRelativeUrl($new_path)
                $global:new_context.Load($file)
                $global:new_context.ExecuteQuery()
            }else{
                $target = $global:new_context.Web.GetFolderByServerRelativeUrl((Split-Path -Path $new_path))
            
                $info = New-Object Microsoft.SharePoint.Client.FileCreationInformation
                $info.Overwrite = $true
                $info.ContentStream = $stream
                $info.URL = $new_path
            
                $file = $target.Files.Add($info)  
                $global:new_context.ExecuteQuery()
            }

            $setmeta.Invoke($file)
            
            return $true
        }
        
        while(!$success){
            if($attempt -eq 2){
                #Util-RefreshConnections

            }elseif($attempt -gt 2){
                Read-Host "Upload (and overwrite) the file manually and press enter when finished"
                
                try {
                    $file = $global:new_context.Web.GetFileByServerRelativeUrl($new_path)
                    $global:new_context.Load($file)
                    $global:new_context.ExecuteQuery()
                    $setmeta.Invoke($file)
                    
                    return $true
                } catch {
                    Util-HandleError "Setting Meta failed: $($_.Exception.Message)"
                }
            }

            $attempt++

            try {
                $success = $upload.Invoke()
            } catch {
                Write-Host "Upload failed: $($_.Exception.Message)"
            }
        }
    }
}