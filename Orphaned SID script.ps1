## This PowerShell script identifies and resolves SID collisions in user profiles by mapping SIDs to profile paths, logging the results, and allowing the user to delete duplicate SIDs.
## Author: [Allan Walker] July 2025 

# Generate a timestamp for log file naming
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
# Set the path for the log file in the user's profile directory
$logPath = "\\srv-neg-1\neg\Zone Echange\orphaned SID script logs\$($env:COMPUTERNAME) SID_Collision_Report $timestamp.log"
# Ensure the log directory exists, and if not, create it
$logDir = Split-Path -Path $logPath -Parent
if (-not (Test-Path -Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory -Force
}

# Define the registry path for user profile SIDs
$profileListPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
# Hashtable to map profile paths to SIDs
# profilemap tracks the user SID to profile path 
$profileMap = @{}
# Array to store duplicate SIDs
$duplicateSIDs = @()
# Array to store SIDs that could not be resolved to an account
$unresolvedSIDs = @()

# Log the start of the SID to profile path mapping
Add-Content $logPath "$env:COMPUTERNAME $timestamp"
Add-Content $logPath "`n=== SID to Profile Path Mapping ===`n"

try {
    # Get all profile registry entries
    $regProfiles = Get-ChildItem $profileListPath
    foreach ($reg in $regProfiles) {
        $sid = $reg.PSChildName
        # Attempt to get the profile path for this SID
        $profilePath = (Get-ItemProperty -Path $reg.PSPath -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
        if ($profilePath) {
            # Log the SID to profile path mapping
            Add-Content $logPath "$sid => $profilePath"

            # Track duplicates: if the profile path already exists, add SID to the array; otherwise, create a new array
            if ($profileMap.ContainsKey($profilePath)) {
                $profileMap[$profilePath] += $sid
            } else {
                $profileMap[$profilePath] = @($sid)
            }
        }
    }

    # Log the start of the duplicate profile folder section
    Add-Content $logPath "`n=== Profile Folder Duplicates ===`n"
    foreach ($path in $profileMap.Keys) {
        if ($profileMap[$path].Count -gt 1) {
            # Log all SIDs that point to the same profile path
            Add-Content $logPath "Multiple SIDs point to ${path}:"
            foreach ($sid in $profileMap[$path]) {
                Add-Content $logPath "   - $sid"
                # Add duplicate SIDs to the array for further processing
                $duplicateSIDs += $sid
            }
        }
    }

} catch {
    # Log any errors encountered while accessing the registry
    Add-Content $logPath "Registry access error: $_"
}

# Notify user that the collision report has been saved
Write-Host "SID collision report saved to: $logPath"

## resolve from list of duplicate SIDs 

# Attempt to resolve each duplicate SID to an account name
foreach ($sid in $duplicateSIDs) {
    try {
        $user = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $name = $user.Translate([System.Security.Principal.NTAccount])
        Write-Host "$sid -> $name"
        Write-Host "" # new line
        } catch {
        # If SID cannot be resolved, log and store for further processing
        Write-Host "$sid -> [Could not resolve SID]"
        Add-Content $logPath "$sid -> [Could not resolve SID]"
        # write unresolved SID to variable for further processing
        $unresolvedSIDs += $sid
    }
}
# For each profile path with duplicate SIDs, prompt the user to resolve the collision
foreach ($path in $profileMap.Keys) {
    if ($profileMap[$path].Count -gt 1) {
        # Print a header for the collision group
        Write-Host "`n=== Collision for Profile Folder: $path ===" -ForegroundColor Cyan
        $sidOptions = @()

        # Build a list of SIDs and their corresponding account names (or unresolved)
        for ($i = 0; $i -lt $profileMap[$path].Count; $i++) {
            $sid = $profileMap[$path][$i]
            try {
                $account = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount])
            } catch {
                $account = "[Unresolved SID]"
            }
            # Store index, SID, and account for user selection
            $sidOptions += [PSCustomObject]@{
                Index = $i
                SID = $sid
                Account = $account
            }
        }

        # delete all orphaned SIDs
        foreach ($opt in $sidOptions) {
            if ($opt.Account -eq "[Unresolved SID]") {
                $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($opt.SID)"
                if (Test-Path $regPath) {
                    Remove-Item -Path $regPath -Recurse -Force
                    Write-Host "Removed orphaned SID: $($opt.SID)" -ForegroundColor Green
                    Add-Content $logPath "Removed orphaned SID from registry: $($opt.SID)"
                }
            }
        }

        # Display all SID options for this profile path to the user
        <# foreach ($opt in $sidOptions) {
            Write-Host "$($opt.Index): $($opt.SID) => $($opt.Account)"
        } #>

        # # Prompt user to select which SIDs to delete
        # $toDelete = Read-Host "Enter index(es) of SID(s) to delete (comma-separated), or leave blank to skip"
        # if ($toDelete) {
        #     $indices = $toDelete -split "," | ForEach-Object { $_.Trim() }
        #     foreach ($idx in $indices) {
        #         # Find the selected SID by index
        #         $match = $sidOptions | Where-Object { $_.Index -eq [int]$idx }
        #         if ($match) {
        #             $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($match.SID)"
        #             if (Test-Path $regPath) {
        #                 # Remove the selected SID from the registry
        #                 Remove-Item -Path $regPath -Recurse -Force
        #                 Write-Host "Removed SID: $($match.SID)" -ForegroundColor Green
        #                 Add-Content $logPath "Removed SID from registry: $($match.SID)"
        #             } else {
        #                 Write-Host "Registry path not found: $regPath" -ForegroundColor Red
        #             }
        #         } else {
        #             Write-Host "Invalid index: $idx" -ForegroundColor Yellow
        #         }
        #     }
        # } else {
        #     # User chose to skip deletion for this profile path
        #     Write-Host "Skipped this profile folder." -ForegroundColor DarkGray
        # }
    }
}

# Summary output to log file    
Add-Content $logPath "`n=== Summary ==="
Add-Content $logPath "Duplicate SIDs found: $($duplicateSIDs.Count)"
Add-Content $logPath "Unresolved SIDs: $($unresolvedSIDs.Count)"
