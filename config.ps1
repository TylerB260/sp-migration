# e.g. "C:\Users\administrator\Desktop\migration\"
$root_path = (Get-Directory)

# username / password combo 
$new_username = 'tbundy@hurleyandassociates.com'
$new_password = 'P@$$word'

# fallback - if the creator/modifier user account no longer exists, attribute it to this user. Doesn't need a license.
$fallback_email = 'fallback@exampletennant.onmicrosoft.com'