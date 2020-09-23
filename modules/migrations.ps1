$migrations = @();

################
################
## Accounting ##
################
################

$migrations += @{ 
    old_site = "Accounting"; # old sharepoint URL had sites at / instead of /sites/
    new_site = "sites/Accounting";
    
    libraries = @{
        "Documents" = "Shared Documents"; 
        "Commissions" = "Commission Folder"
    };
};

###############
###############
## Root Site ##
###############
###############
    
# Employee Doucments #
$migrations += @{
    old_site = ""; # both are on the home page site still
    new_site = "";
    
    libraries = @{
        "Employees Documents" = "Employee Documents"; # different folder names!
    };
};

# Information Technology Files #
$migrations += @{
    old_site = ""; # used to be on home page
    new_site = "sites/IT"; # now on it's own site
    
    libraries = @{
        "Information Technology" = "Shared Documents"; # move to the "documents" folder instead
    };
};

# Filter Functions are also supported in the "value" portion of the libraries list. The function gets passed the file path as the only variable, so you can split libraries by first letter for example.
# I had code written to take advantage of this for long term storage of document that were encroaching on the file limit, but unfortunately it was lost.

###################################
###################################
## Office A and Consultant Sites ##
###################################
###################################

# OfficeA #
$migrations += @{
    old_site = "OfficeA";
    new_site = "sites/OfficeA";
    
    libraries = @{
        "Archive" = "Archive";
        "Compliance" = "Compliance";
        "Events" = "Office Events";
        "Office Documents" = "Office Documents";
        "Office Pictures" = "Office Pictures"
    };
};

# OfficeA - John Doe #
$migrations += @{
    old_site = "OfficeA/JohnD";
    new_site = "sites/OfficeA";
    
    # before, employee had his own subsite on an office. Now they just have a document library. Hence the folder layout below.
    libraries = @{
        "Archive" = "JohnD/Archive";
        "Statements" = "JohnD/Statements";
        "Orders" = "JohnD/Orders";
        "Clients" = "JohnD/Clients";
        "Documents" = "JohnD/Documents";
        "Reports" = "JohnD/Reports"
    };
};
