$source = "c:\MyApps\PZ Mods\AuroraLifeLocal"
$dest = "c:\MyApps\PZ Mods\AuroraLife"

# Copy all contents from Local Dev to Release, skipping the .git folder and VS Code workspace files
# Using robocopy /MIR to perfectly mirror the directory (deletes files that no longer exist in source)
robocopy "$source" "$dest" /MIR /XD .git /XF *.code-workspace /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null

# Update mod.info files to reset the ID and Name back to the Release version
$modInfo = "$dest\mod.info"
(Get-Content $modInfo) -replace 'id=AuroraLifeLocal\s*$', 'id=AuroraLife' -replace 'name=AuroraLifeLocal\s*$', 'name=AuroraLife' | Set-Content $modInfo

$commonModInfo = "$dest\common\mod.info"
if (Test-Path $commonModInfo) {
    (Get-Content $commonModInfo) -replace 'id=AuroraLifeLocal\s*$', 'id=AuroraLife' -replace 'name=AuroraLifeLocal\s*$', 'name=AuroraLife' | Set-Content $commonModInfo
}

Write-Host "Successfully synced AuroraLifeLocal (Development) to AuroraLife (Release)!"

# Also copy to the Workshop upload directory if it exists
$workshopDest = "$env:USERPROFILE\Zomboid\Workshop\AuroraLife\Contents\mods\AuroraLife"
if (Test-Path $workshopDest) {
    robocopy "$dest" "$workshopDest" /MIR /XD .git /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
    Write-Host "Successfully copied release files to Zomboid Workshop directory for Steam upload!"
} else {
    Write-Host "Workshop directory not found, skipping Workshop sync."
}
