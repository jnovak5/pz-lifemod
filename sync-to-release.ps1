$source = "c:\MyApps\PZ Mods\AuroraLifeLocal"
$dest = "c:\MyApps\PZ Mods\AuroraLife"

# Copy all contents from Local Dev to Release, skipping the .git folder and VS Code workspace files
Copy-Item -Path "$source\*" -Destination $dest -Recurse -Force -Exclude "*.code-workspace"

# Update mod.info to reset the ID and Name back to the Release version
$modInfo = "$dest\common\mod.info"
(Get-Content $modInfo) -replace 'id=AuroraLifeLocal$', 'id=AuroraLife' -replace 'name=AuroraLife \(Local Dev\)', 'name=AuroraLife' | Set-Content $modInfo

Write-Host "Successfully synced AuroraLifeLocal (Development) to AuroraLife (Release)!"

# Also copy to the Workshop upload directory if it exists
$workshopDest = "$env:USERPROFILE\Zomboid\Workshop\AuroraLife\Contents\mods\AuroraLife"
if (Test-Path $workshopDest) {
    Copy-Item -Path "$dest\*" -Destination $workshopDest -Recurse -Force
    Write-Host "Successfully copied release files to Zomboid Workshop directory for Steam upload!"
} else {
    Write-Host "Workshop directory not found, skipping Workshop sync."
}
