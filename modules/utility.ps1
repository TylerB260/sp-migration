function Util-ConnectOldSharePoint(){
    # SharePoint OnPrem
    Connect-PnPOnline -Url "$old_url/$old_site" -UseWebLogin -ErrorAction Inquire
    $global:old_context = Get-PnPContext
}

function Util-ConnectNewSharePoint(){
    # SharePoint Online - reconnect every library so our creds don't expire.
    $baseenc = [System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($new_password))
    $cred = New-Object -typename System.Management.Automation.PSCredential -argumentlist $new_username, (ConvertTo-SecureString -String $baseenc -AsPlainText -Force)
    Connect-PnPOnline -Url "$new_url/$new_site" -Credential $cred -ErrorAction Inquire
    $global:new_context = Get-PnPContext
}

function Util-ChangeContext(){
    param(
        $context
    )

    Set-PnPContext -Context $context

    # https://github.com/SharePoint/PnP-PowerShell/issues/849#issuecomment-316056094

    $connection = [SharePointPnP.PowerShell.Commands.Base.SPOnlineConnection]::CurrentConnection
    $connection.GetType().GetProperty("Url").SetValue($connection, $context.Url)
}

$field_cache = @{}  

# this function grabs the author editor etc. columns and any custom columns.
function Util-DetermineFields(){
    param(
        $list,
        $context = (Get-PnPContext)
    )

    $whitelist = @(
        "Author",
        "Editor",

        "Created",
        "Modified"
    )

    $blacklist = @(
        "Combine",
        "RepairDocument",
        "Url",
        "_ShortcutUrl",
        "_ShortcutWebId",
        "_ShortcutSiteId",
        "_ShortcutUniqueId",
        "IconOverlay"
    )

    $uid = "$($context.Url)|$list"
    if($field_cache[$uid]){return $field_cache[$uid]}

    $temp_context = Get-PnPContext
    Util-ChangeContext $context
   
    $list = Get-PnPList -Identity $list.Split("/")[0]
    $fields = $list.Fields

    $context.Load($list.Fields)
    $context.ExecuteQuery()

    $out = @{}

    $fields | foreach {
        if(($_.CanBeDeleted -and $blacklist -notcontains $_.InternalName) -or $whitelist -contains $_.InternalName){
            $out[$_.InternalName] = $_
        }
    }

    Util-ChangeContext $temp_context

    $field_cache[$uid] = $out
    return $out
}

function Util-SanitizeValue(){
    param(
        $value,
        $context = (Get-PnPContext)
    )

    if(!$value){return $null}

    # choice column #
    if($value.GetType().FullName -eq "System.String[]"){$value = $value[0];}
    # user values #        
    if($value.GetType().FullName -eq "Microsoft.SharePoint.Client.FieldUserValue"){
        $value = (Util-GrabUser -id $value.LookupId -context $context)
    }

    return $value
}

function Util-DetermineValues(){
    param(
        $old_item,
        $new_item,
        $EnableVersioning = $true
    )

    $out = @{}
    $old_fields = Util-DetermineFields -list $old_library -context $global:old_context
    $new_fields = Util-DetermineFields -list $new_library -context $global:new_context

    foreach($id1 in $old_fields.Keys){
        $old_field = $old_fields[$id1]
        $old_value = (Util-SanitizeValue -value $old_item.FieldValues[$old_field.InternalName] -context $global:old_context)
        
        $found = $false
        $modified = $false

        foreach($id2 in $new_fields.Keys){
            $new_field = $new_fields[$id2]
            $new_value = $null
            
            if($new_item){
                $new_value = (Util-SanitizeValue -value $new_item.FieldValues[$new_field.InternalName] -context $global:new_context)
            }

            if($old_field.Title -eq $new_field.Title){
                $out[$new_field.InternalName] = $old_value
                $found = $true
                    
                if($old_value -ne $new_value){
                    #Write-Host "Old $($old_field.Title): $($old_value)"
                    #Write-Host "New $($new_field.Title): $($new_value)"

                    # users don't return true - do further testing
                    if(($old_value.GetType().FullName -eq "Microsoft.SharePoint.Client.User") -and ($old_value.Email -eq $new_value.Email)){break}
                    
                    $modified = $true
                }

                break
            }
        }

        if(!$found){Util-HandleError "No column was found for $($old_field.Title) on the new Document Library."}
    }

    if($EnableVersioning -and ($old_item.FieldValues.File_x0020_Size -ne "") -and ($old_item.FieldValues._UIVersionString -ne $new_item.FieldValues._UIVersionString)){
        #Write-Host "File versioning does not match; check the file version manually."
        $modified = $true
    }

    return @{Modified = $modified; Values = $out}
}


function Util-FixPath(){
    param(
        $path = ""
    )

    return $path.Replace("//", "/").Replace("\\", "\").Replace("\", "/")
}

function Util-HandleError(){
    param(
        $str
    )

    Write-Host $str -ForegroundColor Red
    Read-Host "Press enter to continue"
    exit
}

$global:user_cache = @{};

function Util-GrabUser(){
    param(
        $user,
        $str,
        $id,
        $context = $global:new_context
    )

    $temp_context = Get-PnPContext
    $uid = $context.Url
    $out = $null
    $cache = $false

    Util-ChangeContext $context
    
    if(!$global:user_cache[$uid]){$global:user_cache[$uid] = @{};}
    
    if($user -ne $null){
        if($global:user_cache[$uid][$user.LookupId]){
            $out = $global:user_cache[$uid][$user.LookupId]
            $cache = $true
        }else{
            $out = New-PnPUser -LoginName $user.Email -ErrorAction SilentlyContinue
        }
    }elseif($str -ne $null){
        if($global:user_cache[$uid][$str]){
            $out = $global:user_cache[$uid][$str]
            $cache = $true
        }else{
            $out = New-PnPUser -LoginName $str -ErrorAction SilentlyContinue
        }
    }elseif($id -ne $null){
        if($global:user_cache[$uid][$id]){
            $out = $global:user_cache[$uid][$id]
            $cache = $true
        }else{
            $out = Get-PnPUser -Identity $id -ErrorAction SilentlyContinue
        }
    }

    Util-ChangeContext $global:new_context

    if(!$cache){
        # return the 365 equivalent for onprem users.
        if($out -and ($context -eq $global:old_context)){
            $out = New-PnPUser -LoginName $out.LoginName.SubString($out.LoginName.lastIndexOf("|") + 1) -ErrorAction SilentlyContinue
        }

        # if no user, use fallback. if user, add it to our cache.
        if($out -eq $null){
            $out = New-PnPUser -LoginName $fallback_email
        }

        # use loginname as email if email is not set.
        if(($out.Email -eq $null) -or ($out.Email -eq "")){
            #Write-Host "Fixing Email for $($out.Title)"
            $out.Email = $out.LoginName.SubString($out.LoginName.lastIndexOf("|") + 1)
        }

        if($user -ne $null){$global:user_cache[$uid][$user] = $out}
        if($str -ne $null){$global:user_cache[$uid][$str] = $out}
        if($id -ne $null){$global:user_cache[$uid][$id] = $out}

        #Write-Host "NOT USING CACHE: $id Cache: $($global:user_cache[$uid].Count) $uid"
    }else{
        #Write-Host "USING CACHE: $id Cache: $($global:user_cache[$uid].Count) $uid"
    }

    Util-ChangeContext $temp_context

    return $out
}
