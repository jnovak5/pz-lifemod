$source = "c:\MyApps\PZ Mods\[SVRP] LifeLocal"
$dest = "c:\MyApps\PZ Mods\[SVRP] Life"

# Copy all contents from Local Dev to Release, skipping the .git folder, .agents, and dev-only files
# Using robocopy /MIR to perfectly mirror the directory (deletes files that no longer exist in source)
robocopy "$source" "$dest" /MIR /XD .git .agents .vscode workshop /XF *.code-workspace sync-to-release.ps1 .gitignore /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null

# Update mod.info files to reset the ID and Name back to the Release version
$modInfo = "$dest\mod.info"
(Get-Content $modInfo) -replace 'id=[SVRP] LifeLocal\s*$', 'id=[SVRP] Life' -replace 'name=[SVRP] LifeLocal\s*$', 'name=[SVRP] Life' | Set-Content $modInfo

$commonModInfo = "$dest\common\mod.info"
if (Test-Path $commonModInfo) {
    (Get-Content $commonModInfo) -replace 'id=[SVRP] LifeLocal\s*$', 'id=[SVRP] Life' -replace 'name=[SVRP] LifeLocal\s*$', 'name=[SVRP] Life' | Set-Content $commonModInfo
}

Write-Host "Successfully synced [SVRP] LifeLocal (Development) to [SVRP] Life (Release)!"

# Also copy to the Workshop upload directory if it exists
$workshopDest = "$env:USERPROFILE\Zomboid\Workshop\[SVRP] Life\Contents\mods\[SVRP] Life"
if (Test-Path $workshopDest) {
    robocopy "$dest" "$workshopDest" /MIR /XD .git .agents .vscode workshop /XF *.code-workspace sync-to-release.ps1 .gitignore /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
    Write-Host "Successfully copied release files to Zomboid Workshop directory for Steam upload!"
} else {
    Write-Host "Workshop directory not found, skipping Workshop sync."
}

