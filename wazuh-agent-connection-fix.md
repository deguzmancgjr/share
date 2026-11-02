# Troubleshooting & Resolution: Connecting BT6-DND-* VMs to Wazuh Manager (VM 198)

This guide documents the root cause analysis, architecture, and step-by-step procedures to connect all **`BT6-DND-*`** virtual machines to **`BT6-DND-Wazuh` (VM 198)**.

---

## 1. Environment & Systems Matrix

| Host / VM | VM ID | OS / Role | IP Address | Wazuh Agent Name | Port / Protocol | Connection Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **BT6-DND-Wazuh** | **198** | Wazuh Manager (Linux) | **`10.6.0.10`** | Manager Server | `1514` (Agent), `1515` (Enroll) | **Active & Listening** |
| **BT6-DND-DC** | **138** | Windows Server 2022 (DC) | `10.2.229.78` & `10.6.0.2` | `DND-DC` | TCP `1514`/`1515` | **Connected & Online** |
| **BT6-WS1** | **107** | Windows 10 Pro (WS1) | `10.6.0.4` | `BT6-DND-WS1` | TCP `1514`/`1515` | **Connected & Online** |
| **BT6-WS2** | **166** | Windows 10 Pro (WS2) | `10.6.0.5` | `BT6-DND-WS2` | TCP `1514`/`1515` | **Connected & Online** |
| **BT6-WS3** | **182** | Windows 10 Pro (WS3) | `10.6.0.6` | `BT6-DND-WS3` | TCP `1514`/`1515` | **Connected & Online** |
| **BT6-WS4** | **183** | Windows 10 Pro (WS4) | `10.6.0.7` | `BT6-DND-WS4` | TCP `1514`/`1515` | **Connected & Online** |
| **BT6-FileSvr** | **158** | Windows Server (FileSvr) | `10.6.0.3` | `BT6-DND-FileSvr` | TCP `1514`/`1515` | *Action Required (Sec 4)* |

---

## 2. Root Cause Analysis: Why Connections Failed

During our live infrastructure investigation, we identified **three distinct blockers** preventing the agents from communicating with Wazuh Manager:

### Blocker 1: Incorrect Manager Address in `ossec.conf`
The Wazuh Manager is running on **`10.6.0.10`** (ports 1514, 1515, 443, 55000). However:
* **VM 107** was pointing to `<address>dnd.local</address>`, which resolved to `10.2.229.78` (the Domain Controller). The DC does not run Wazuh, causing:
  `ERROR: (1208): Unable to connect to enrollment service at '[10.2.229.78]:1515'`.
* **VMs 166, 182, 183, and 158** were cloned from an old template pointing to `<address>10.5.0.10</address>` (the old VISCOM subnet), which was unreachable.

### Blocker 2: Duplicate Hardcoded Agent Name (`VISCOM-WS1`)
In `ossec.conf` under `<enrollment>`, the template had hardcoded `<agent_name>VISCOM-WS1</agent_name>`.
When multiple VMs attempted to auto-enroll, Wazuh Manager rejected all subsequent attempts with:
`ERROR: Duplicate agent name: VISCOM-WS1. Unable to add agent (from manager)`.
* **Resolution**: Each VM must have a unique `<agent_name>` matching its hostname (e.g., `BT6-DND-WS1`, `BT6-DND-WS2`, etc.).

### Blocker 3: Network Isolation on Domain Controller (VM 138)
The Domain Controller (VM 138) was originally configured with only one network interface on `vmbr0` (`10.2.229.78/24`). The Wazuh manager (`10.6.0.10`) is located on `vmbr1` behind pfSense 118.
Because there was no route between `10.2.229.0/24` and `10.6.0.0/24`, DC 138 could not send traffic to `10.6.0.10`.
* **Resolution**: Adding a second NIC (`net1`) on `bridge=vmbr1` with IP **`10.6.0.2/24`** directly connected DC 138 to the same Layer 2 network as Wazuh, enabling instant communication without routing barriers.

---

## 3. Automated Configuration via Proxmox Host CLI

The following commands fix the configuration, update agent names, remove stale cryptographic keys, and restart the Wazuh agent service.

### Step 3.1: Configure DC 138 Network & Agent (Already Applied)

```bash
# 1. Add secondary NIC on vmbr1 (if not already added)
qm set 138 -net1 e1000,bridge=vmbr1,firewall=1

# 2. Assign static IP 10.6.0.2 (no gateway, preserving primary default gateway)
qm guest exec 138 powershell.exe -- -Command '
New-NetIPAddress -InterfaceAlias "Ethernet 2" -IPAddress "10.6.0.2" -PrefixLength 24 -ErrorAction SilentlyContinue
'

# 3. Configure Wazuh Agent and Restart
qm guest exec 138 powershell.exe -- -Command '
$conf = "C:\Program Files (x86)\ossec-agent\ossec.conf"
(Get-Content $conf) -replace "<address>.*?</address>", "<address>10.6.0.10</address>" | Set-Content $conf
Restart-Service WazuhSvc
'
```

### Step 3.2: Configure Workstations (VMs 107, 166, 182, 183)

Run this block directly on the Proxmox host to configure all workstations:

```bash
# VM 107 (BT6-WS1)
qm guest exec 107 powershell.exe -- -Command '
Stop-Service WazuhSvc -ErrorAction SilentlyContinue
$c = "C:\Program Files (x86)\ossec-agent\ossec.conf"
(Get-Content $c) -replace "<address>.*?</address>", "<address>10.6.0.10</address>" -replace "<agent_name>.*?</agent_name>", "<agent_name>BT6-DND-WS1</agent_name>" | Set-Content $c
Remove-Item "C:\Program Files (x86)\ossec-agent\client.keys" -Force -ErrorAction SilentlyContinue
Start-Service WazuhSvc
'

# VM 166 (BT6-WS2)
qm guest exec 166 powershell.exe -- -Command '
Stop-Service WazuhSvc -ErrorAction SilentlyContinue
$c = "C:\Program Files (x86)\ossec-agent\ossec.conf"
(Get-Content $c) -replace "<address>.*?</address>", "<address>10.6.0.10</address>" -replace "<agent_name>.*?</agent_name>", "<agent_name>BT6-DND-WS2</agent_name>" | Set-Content $c
Remove-Item "C:\Program Files (x86)\ossec-agent\client.keys" -Force -ErrorAction SilentlyContinue
Start-Service WazuhSvc
'

# VM 182 (BT6-WS3)
qm guest exec 182 powershell.exe -- -Command '
Stop-Service WazuhSvc -ErrorAction SilentlyContinue
$c = "C:\Program Files (x86)\ossec-agent\ossec.conf"
(Get-Content $c) -replace "<address>.*?</address>", "<address>10.6.0.10</address>" -replace "<agent_name>.*?</agent_name>", "<agent_name>BT6-DND-WS3</agent_name>" | Set-Content $c
Remove-Item "C:\Program Files (x86)\ossec-agent\client.keys" -Force -ErrorAction SilentlyContinue
Start-Service WazuhSvc
'

# VM 183 (BT6-WS4)
qm guest exec 183 powershell.exe -- -Command '
Stop-Service WazuhSvc -ErrorAction SilentlyContinue
$c = "C:\Program Files (x86)\ossec-agent\ossec.conf"
(Get-Content $c) -replace "<address>.*?</address>", "<address>10.6.0.10</address>" -replace "<agent_name>.*?</agent_name>", "<agent_name>BT6-DND-WS4</agent_name>" | Set-Content $c
Remove-Item "C:\Program Files (x86)\ossec-agent\client.keys" -Force -ErrorAction SilentlyContinue
Start-Service WazuhSvc
'
```

---

## 4. Specific Procedure for File Server (VM 158)

Because the QEMU guest agent is not currently active on VM 158, apply the fix inside the VM:

1. Connect to VM 158 via **Guacamole** (`https://10.2.229.50/guacamole/`) or via Proxmox Console (`>_ Console`).
2. Right-click the Start Menu and open **Windows PowerShell (Admin)**.
3. Paste and run the following script:

```powershell
# Stop service
Stop-Service WazuhSvc -ErrorAction SilentlyContinue

# Update configuration file
$confPath = "C:\Program Files (x86)\ossec-agent\ossec.conf"
$content = Get-Content $confPath
$content = $content -replace "<address>.*?</address>", "<address>10.6.0.10</address>"
$content = $content -replace "<agent_name>.*?</agent_name>", "<agent_name>BT6-DND-FileSvr</agent_name>"
Set-Content -Path $confPath -Value $content

# Remove old registration key
Remove-Item "C:\Program Files (x86)\ossec-agent\client.keys" -Force -ErrorAction SilentlyContinue

# Restart service
Start-Service WazuhSvc

# Optional: Enable QEMU Guest Agent so Proxmox CLI commands work in future
Set-Service -Name "QEMU-GA" -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue
```

4. Confirm enrollment by checking the log:
```powershell
Get-Content "C:\Program Files (x86)\ossec-agent\ossec.log" -Tail 10
```
*Expected: `Valid key received` and `Agent is now online`.*

---

## 5. Verification & Health Checks

### 5.1 Check Live Agent Status from Proxmox CLI
Run this command from the Proxmox host terminal to check all online agents simultaneously:

```bash
for vmid in 107 166 182 183 138; do
  echo "=== VM $vmid Wazuh Status ==="
  qm guest exec $vmid powershell.exe -- -Command "Get-Content 'C:\Program Files (x86)\ossec-agent\ossec.log' -Tail 3 | Select-String -Pattern 'Agent is now online|Started|Valid key|Real-time'"
done
```

**Verified Output**:
```text
=== VM 107 Wazuh Status ===
2026/11/02 10:12:33 wazuh-agent: INFO: (6012): Real-time file integrity monitoring started.

=== VM 166 Wazuh Status ===
2026/11/02 10:20:13 wazuh-agent: INFO: Started (pid: 7288).

=== VM 182 Wazuh Status ===
2026/11/02 10:19:31 wazuh-agent: INFO: Valid key received

=== VM 183 Wazuh Status ===
2026/11/02 10:20:30 wazuh-agent: INFO: Valid key received

=== VM 138 Wazuh Status ===
2026/11/02 10:18:51 wazuh-agent: INFO: (6012): Real-time file integrity monitoring started.
```

### 5.2 Wazuh Web Dashboard
Open your browser and navigate to:
```
https://10.6.0.10/
```
*(Accept the self-signed certificate, log in, and navigate to **Endpoints Summary** to see all `BT6-DND-*` systems reporting as Active).*

---

## 6. Summary of Key Configuration Settings

| Parameter | Location in `ossec.conf` | Correct Value |
| :--- | :--- | :--- |
| **Manager Address** | `<client><server><address>` | **`10.6.0.10`** |
| **Manager Port** | `<client><server><port>` | `1514` |
| **Protocol** | `<client><server><protocol>` | `tcp` |
| **Auto-Enrollment** | `<client><enrollment><enabled>` | `yes` |
| **Agent Name** | `<client><enrollment><agent_name>` | `BT6-DND-WS1` (Unique per VM) |
| **Key Cache** | `C:\Program Files (x86)\ossec-agent\client.keys` | Delete before re-enrolling |
