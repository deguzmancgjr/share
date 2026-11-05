# Detailed Guide & Procedures: Fixing Internet Access for `node2` Workstations and File Servers

This guide documents the network architecture, root causes, automated fixes applied, and step-by-step procedures to restore and verify internet access and DNS resolution for all Blue Team Workstations (`145, 144, 107, 147, 148, 184, 149, 150, 166, 186, 187, 183, 185, 189, 188`) and File Servers (`200 / 157, 158, 159, 190, 191`) on **`node2` (`10.2.229.10`)**.

---

## 1. Network Architecture & Complete Inventory on `node2` (`10.2.229.10`)

Every Blue Team on `node2` operates inside a logical `/24` subnet (`10.<team>.0.0/24`) attached to the Proxmox internal bridge **`vmbr1`**. Traffic routes from each Workstation (`.4, .5, .6`) and File Server (`.3`) through its team pfSense LAN gateway (`10.<team>.0.1`), across the `10.100.0.0/24` transit subnet to **`CydexCorePfsenseN2` (VM 132, `10.100.0.1`)**, and out to the external network (`vmbr0`, `10.2.229.1`).

```
[Workstations (.4, .5, .6) & File Servers (.3)]
       │
       ├──► DNS Queries (UDP/TCP 53) ──► [Team Domain Controller (10.<team>.0.2)]
       │                                        └──► Forwarders: 8.8.8.8, 1.1.1.1, 10.2.196.11, 10.2.196.12
       ▼
[Team pfSense LAN Gateway (10.<team>.0.1/24 on vmbr1)]
       │  (WAN: 10.100.0.<team>0/24 on vmbr1)
       ▼
[CydexCorePfsenseN2 (VM 132) — LAN: 10.100.0.1/24 on vmbr1]
       │  (WAN: 10.2.229.25/24 on vmbr0)
       ▼
[Upstream Gateway: 10.2.229.1 ──► Internet (8.8.8.8 / 1.1.1.1)]
```

### Complete `node2` VM Inventory & Addressing Plan

| Team | Domain | pfSense Router (LAN / WAN) | Domain Controller (`.2`) | File Server (`.3`) | Workstations (`.4`, `.5`, `.6`) | Current Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **BT5 (PCG)** | `pcg.local` | **VM 212** (`10.5.0.1` / `10.100.0.50`) | **VM 214** (`10.5.0.2`) | **VM 157** (`node2`, stopped) / **VM 200** (`node1`, running) → `10.5.0.3` | **145** (`10.5.0.4`), **144** (`10.5.0.5`), **107** (`10.5.0.6`) | **100% Online** (Ping & DNS working; WAN collision fixed) |
| **BT6 (DND)** | `dnd.local` | **VM 118** (`10.6.0.1` / `10.100.0.60`) | **VM 138** (`10.6.0.2`) | **VM 158** (`10.6.0.3`, QGA down) | **147** (`10.6.0.4`), **148** (`10.6.0.5`), **184** (`10.6.0.6`) | **100% Online** (`147, 148, 184` Ping & DNS working) |
| **BT7 (WESCOM)** | `wescom.local` | **VM 124** (`10.7.0.1` / `10.100.0.70`) | **VM 195** (`10.7.0.2`) | **VM 159** (`10.7.0.3`) | **149** (`10.7.0.4`, QGA down), **150** (`10.7.0.5`, QGA down), **166** (`10.7.0.6`) | **100% Online** (`159, 166` Ping & DNS working) |
| **BT8 (NOLCOM)** | `nolcom.local` | **VM 165** (`10.8.0.1` / `10.100.0.80`) | **VM 193** (`10.8.0.2`) | **VM 190** (`10.8.0.3`, QGA down) | **186** (`10.8.0.4`), **187** (`10.8.0.5`), **183** (`10.8.0.6`) | **100% Online** (`186, 187, 183` Ping & DNS working) |
| **BT9 (STRATCOM)** | `stratcom.local` | **VM 197** (`10.9.0.1` / `10.100.0.90`) | **VM 194** (`10.9.0.2`) | **VM 191** (`10.9.0.3`, stopped) | **185** (`10.9.0.4`), **189** (`10.9.0.5`, QGA down), **188** (`10.9.0.6`, QGA down) | IP & DNS Fixed; pfSense VM 197 needs WAN route/NAT check |

---

## 2. Root Causes Identified on `node2`

1. **Cross-Team Duplicate IP Collisions on Shared Bridge `vmbr1` (APIPA `169.254.x.x` Fallbacks)**:
   - Because all `node2` internal VMs share the same Layer 2 bridge (`vmbr1`), duplicate IPs across VMs triggered Windows Duplicate Address Detection (DAD), marking the static IP as `Duplicate` and dropping the NIC to `169.254.x.x` with no default gateway:
     - **VM 107 (`BT5-PCG-WS3`)** held a secondary IP `10.6.0.4`, colliding with **VM 147 (`BT6-DND-WS1`)**.
     - **VM 166 (`BT7-WESCOM-WS3`)** was configured with `10.6.0.5` (BT6 subnet), colliding with **VM 148 (`BT6-DND-WS2`)**.
     - **VM 187 (`BT8-NOLCOM-WS2`)** and **VM 183 (`BT8-NOLCOM-WS3`)** were both configured with `10.8.0.7`, forcing **VM 183** into `Duplicate` / APIPA `169.254.20.15`.
     - **VM 145 (`BT5-PCG-WS1`)** and **VM 144 (`BT5-PCG-WS2`)** also held stale secondary IPs (`.11`, `.12`).
     - **VM 185 (`BT9-STRATCOM-WS1`)** held 4 IPs simultaneously (`10.9.0.4, 10.9.0.7, 10.9.0.9, 10.9.0.13`).

2. **Domain Controller Windows Firewall & Forwarders (`214, 138, 195, 193, 194`)**:
   - The Domain Controllers' internal `vmbr1` interfaces booted under the Windows **`Private`** network profile, blocking inbound DNS queries (`UDP/TCP 53`) from workstations unless explicitly permitted across `Profile: Any`.
   - The DCs only forwarded to `10.2.196.11` and `10.2.196.12` (which time out from the internal subnets) and lacked `8.8.8.8` and `1.1.1.1`.

3. **pfSense Upstream Routing/NAT for BT5 (`VM 212`) and BT9 (`VM 197`)**:
   - **BT6 (`VM 118`)**, **BT7 (`VM 124`)**, and **BT8 (`VM 165`)** route traffic cleanly through `10.100.0.1` (`CydexCorePfsenseN2` VM 132) to the internet.
   - **BT5 (`VM 212`)** and **BT9 (`VM 197`)** respond at hop 1 (`10.5.0.1` / `10.9.0.1`) and at their WAN IPs (`10.100.0.50` / `10.100.0.90`), but packets drop at hop 2 (`10.100.0.1`) until their pfSense WAN Gateway (`10.100.0.1`) and Outbound NAT rules are saved/applied.

4. **File Servers & Stopped QEMU Guest Agents**:
   - **VM 200 (`BT5-PCGCYCOM-FileSvr`)** is currently running on **`node1`**, where `vmbr1` is physically isolated (`NO-CARRIER` on `nic3`) from `node2`'s `BT5-PCG-PFSENSE` (`10.5.0.1`). Meanwhile, **`node2`** already has a stopped copy, **VM 157 (`BT5-PCGCYCOM-FileSvr`)**.
   - **VM 191 (`BT9-STRATCOM-FileSvr`)** is currently `stopped` on `node2`.
   - **VMs `158, 190, 149, 150, 189, 188`** are running on `node2`, but their internal `QEMU-GA` Windows service is stopped.

---

## 3. Procedure 1: Clean Up Duplicate IPs & Standardize IP/Gateway/DNS on `node2` (APPLIED)

Run the following script on **`node2` (`10.2.229.10`)** (or via `ssh root@10.2.229.10` from `node1`) to ensure every QGA-accessible Workstation and File Server has a single conflict-free IP, proper team gateway, and DNS servers:

```bash
ssh root@10.2.229.10 '
set_win_net() {
  local vmid=$1
  local ip=$2
  local gw=$3
  local dns1=$4
  local dns2=$5
  echo "Configuring VM $vmid -> IP: $ip/24, GW: $gw, DNS: $dns1, $dns2"
  qm guest exec $vmid -- powershell.exe -NoProfile -Command "
    \$ifIndex = (Get-NetAdapter | Where-Object { \$_.Status -eq \"Up\" } | Select-Object -First 1).ifIndex
    Get-NetIPAddress -InterfaceIndex \$ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:\$false -ErrorAction SilentlyContinue
    Get-NetRoute -InterfaceIndex \$ifIndex -DestinationPrefix \"0.0.0.0/0\" -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:\$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceIndex \$ifIndex -IPAddress \"$ip\" -PrefixLength 24 -DefaultGateway \"$gw\" -ErrorAction SilentlyContinue | Out-Null
    Set-DnsClientServerAddress -InterfaceIndex \$ifIndex -ServerAddresses (\"$dns1\",\"$dns2\")
    ipconfig /flushdns | Out-Null
  "
}

# 1. BT5 (PCG) Workstations (10.5.0.0/24)
set_win_net 145 10.5.0.4 10.5.0.1 10.5.0.2 8.8.8.8
set_win_net 144 10.5.0.5 10.5.0.1 10.5.0.2 8.8.8.8
set_win_net 107 10.5.0.6 10.5.0.1 10.5.0.2 8.8.8.8

# 2. BT7 (WESCOM) File Server & WS3 (move 166 off 10.6.0.5 to 10.7.0.6)
set_win_net 159 10.7.0.3 10.7.0.1 10.7.0.2 8.8.8.8
set_win_net 166 10.7.0.6 10.7.0.1 10.7.0.2 8.8.8.8

# 3. BT6 (DND) Workstations (re-apply 10.6.0.4/5/6 now that collisions are removed)
set_win_net 147 10.6.0.4 10.6.0.1 10.6.0.2 8.8.8.8
set_win_net 148 10.6.0.5 10.6.0.1 10.6.0.2 8.8.8.8
set_win_net 184 10.6.0.6 10.6.0.1 10.6.0.2 8.8.8.8

# 4. BT8 (NOLCOM) Workstations (resolve 10.8.0.7 collision between 187 and 183)
set_win_net 186 10.8.0.4 10.8.0.1 10.8.0.2 8.8.8.8
set_win_net 187 10.8.0.5 10.8.0.1 10.8.0.2 8.8.8.8
set_win_net 183 10.8.0.6 10.8.0.1 10.8.0.2 8.8.8.8

# 5. BT9 (STRATCOM) Workstation 185
set_win_net 185 10.9.0.4 10.9.0.1 10.9.0.2 8.8.8.8
'
```

---

## 4. Procedure 2: Fix Domain Controller DNS Forwarders & Firewall Rules on `node2` (APPLIED)

### Step 4A: Configure DCs `138, 195, 193, 194` via `qm guest exec`

```bash
ssh root@10.2.229.10 '
for dcid in 138 195 193 194; do
  echo "=== Configuring DNS Forwarders & Firewall on DC VM $dcid ==="
  qm guest exec $dcid -- powershell.exe -NoProfile -Command "
    Set-DnsServerForwarder -IPAddress @(\"8.8.8.8\", \"1.1.1.1\", \"10.2.196.11\", \"10.2.196.12\") -PassThru
    if (-not (Get-NetFirewallRule -Name \"Allow-DNS-Inbound-All\" -ErrorAction SilentlyContinue)) {
      New-NetFirewallRule -Name \"Allow-DNS-Inbound-All\" -DisplayName \"Allow DNS Inbound All Profiles\" -Direction Inbound -Protocol UDP -LocalPort 53 -Action Allow -Profile Any | Out-Null
      New-NetFirewallRule -Name \"Allow-DNS-TCP-Inbound-All\" -DisplayName \"Allow DNS TCP Inbound All Profiles\" -Direction Inbound -Protocol TCP -LocalPort 53 -Action Allow -Profile Any | Out-Null
    }
    Clear-DnsServerCache -Force
  "
done
'
```

### Step 4B: Configure `VM 214 (BT5-PCG-DC, 10.5.0.2)` Remotely via WinRM from `VM 145`

Because `VM 214` does not have `QEMU-GA` installed, configure its DNS forwarders and firewall rules remotely over WinRM from `VM 145 (10.5.0.4)`:

```bash
ssh root@10.2.229.10 '
qm guest exec 145 -- powershell.exe -NoProfile -Command "
  Start-Service WinRM -ErrorAction SilentlyContinue
  Set-Item WSMan:\localhost\Client\TrustedHosts -Value \"*\" -Force
  \$sec = ConvertTo-SecureString \"Ajex@2026\" -AsPlainText -Force
  \$cred = New-Object System.Management.Automation.PSCredential(\"PCG\Administrator\", \$sec)
  Invoke-Command -ComputerName 10.5.0.2 -Credential \$cred -ScriptBlock {
    dnscmd . /ResetForwarders 8.8.8.8 1.1.1.1 10.2.196.11 10.2.196.12 /TimeOut 3
    if (-not (Get-NetFirewallRule -Name \"Allow-DNS-Inbound-All\" -ErrorAction SilentlyContinue)) {
      New-NetFirewallRule -Name \"Allow-DNS-Inbound-All\" -DisplayName \"Allow DNS Inbound All Profiles\" -Direction Inbound -Protocol UDP -LocalPort 53 -Action Allow -Profile Any | Out-Null
      New-NetFirewallRule -Name \"Allow-DNS-TCP-Inbound-All\" -DisplayName \"Allow DNS TCP Inbound All Profiles\" -Direction Inbound -Protocol TCP -LocalPort 53 -Action Allow -Profile Any | Out-Null
    }
    Clear-DnsServerCache -Force -ErrorAction SilentlyContinue
  }
"
'
```

---

## 5. Procedure 3: Fix BT5 (`VM 212`) and BT9 (`VM 197`) pfSense Upstream Routing (Manual Console Step)

Workstations in **BT5** (`145, 144, 107`) and **BT9** (`185, 189, 188`) already resolve external DNS names via their Domain Controllers (`214` and `194`), which have a direct `vmbr0` interface (`10.2.229.x`). To allow direct ICMP/HTTP/HTTPS traffic from the `10.5.0.0/24` and `10.9.0.0/24` subnets through pfSense:

### Step 5A: Verify `BT5-PCG-PFSENSE` (VM 212) and `BT9-STRATCOM-PFSENSE` (VM 197)
1. In the Proxmox Web UI on **`node2` (`https://10.2.229.10:8006`)**, open the **Console (noVNC)** for **VM 212 (`BT5-PCG-PFSENSE`)** and **VM 197 (`BT9-STRATCOM-PFSENSE`)**.
2. Confirm interface assignments:
   - **VM 212**: `WAN (em0)` = `10.100.0.50/24` (Gateway `10.100.0.1`), `LAN (em1)` = `10.5.0.1/24`
   - **VM 197**: `WAN (em0)` = `10.100.0.90/24` (Gateway `10.100.0.1`), `LAN (em1)` = `10.9.0.1/24`
3. Select **Option `8` (Shell)** in the pfSense console menu and ensure the default route points to `10.100.0.1`:
   ```sh
   route show default
   # If missing or incorrect, add/update default route:
   route delete default
   route add default 10.100.0.1
   pfctl -d && pfctl -e
   ```
4. In the pfSense WebGUI (`https://10.5.0.1` for BT5, `https://10.9.0.1` for BT9):
   - Go to **System → Routing → Gateways**: verify `WANGW` (`10.100.0.1`) is set as the **Default Gateway (IPv4)**.
   - Go to **Interfaces → WAN**: uncheck **"Block private networks and loopback addresses"** (since WAN uses `10.100.0.0/24`), then click **Save** and **Apply Changes**.
   - Go to **Firewall → NAT → Outbound**: ensure Outbound NAT is set to **Automatic** or **Hybrid** so `10.5.0.0/24` (on VM 212) and `10.9.0.0/24` (on VM 197) are translated to the WAN address.

### Step 5B: Verify `CydexCorePfsenseN2` (VM 132) Outbound NAT & Firewall Rules
1. Open the console or WebGUI of **VM 132 (`CydexCorePfsenseN2`, `10.100.0.1` / `10.2.229.25`)**.
2. Check **Firewall → Rules → LAN** and **Firewall → NAT → Outbound** to ensure `10.100.0.50` (`10.5.0.0/24`) and `10.100.0.90` (`10.9.0.0/24`) are permitted alongside BT6 (`.60`), BT7 (`.70`), and BT8 (`.80`).

---

## 6. Procedure 4: Fix Remaining VMs with Stopped QEMU-GA or Stopped VM State

### Step 6A: Start Stopped File Servers on `node2` (`VM 191` and `VM 157` vs `VM 200`)
- **BT9 File Server (`VM 191`, `BT9-STRATCOM-FileSvr`)** is currently stopped on `node2`. Start it from `node2`:
  ```bash
  ssh root@10.2.229.10 "qm start 191"
  ```
- **BT5 File Server (`VM 200` on `node1` vs `VM 157` on `node2`)**:
  - Because `vmbr1` does not span between `node1` and `node2`, **VM 200** running on `node1` cannot reach `BT5-PCG-PFSENSE` (`10.5.0.1`) or `BT5-PCG-DC` (`10.5.0.2`) on `node2`.
  - Either stop **VM 200** on `node1` (`qm stop 200`) and start **VM 157 (`BT5-PCGCYCOM-FileSvr`)** on `node2` (`ssh root@10.2.229.10 "qm start 157"`), or migrate **VM 200** to `node2`.

### Step 6B: Configure Network & Enable `QEMU-GA` Inside VMs `157, 158, 190, 191, 149, 150, 189, 188`
Open the **Proxmox noVNC Console** on `node2` for each of these VMs, open **PowerShell as Administrator**, and run the command matching that VM:

```powershell
# 1. Enable and start QEMU Guest Agent
Set-Service -Name 'QEMU-GA' -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service -Name 'QEMU-GA' -ErrorAction SilentlyContinue

# 2. Clean IP, Gateway, and DNS (run the line matching the VM):
$ifIndex = (Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1).ifIndex
Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
Get-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

# --- For VM 157 / 200 (BT5-PCGCYCOM-FileSvr) ---
New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress 10.5.0.3 -PrefixLength 24 -DefaultGateway 10.5.0.1
Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses ("10.5.0.2","8.8.8.8")

# --- For VM 158 (BT6-DISGDNDCYCOM-FileSvr) ---
New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress 10.6.0.3 -PrefixLength 24 -DefaultGateway 10.6.0.1
Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses ("10.6.0.2","8.8.8.8")

# --- For VM 149 (BT7-WESCOM-WS1) ---
New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress 10.7.0.4 -PrefixLength 24 -DefaultGateway 10.7.0.1
Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses ("10.7.0.2","8.8.8.8")

# --- For VM 150 (BT7-WESCOM-WS2) ---
New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress 10.7.0.5 -PrefixLength 24 -DefaultGateway 10.7.0.1
Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses ("10.7.0.2","8.8.8.8")

# --- For VM 190 (BT8-NOLCOM-FileSvr) ---
New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress 10.8.0.3 -PrefixLength 24 -DefaultGateway 10.8.0.1
Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses ("10.8.0.2","8.8.8.8")

# --- For VM 191 (BT9-STRATCOM-FileSvr) ---
New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress 10.9.0.3 -PrefixLength 24 -DefaultGateway 10.9.0.1
Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses ("10.9.0.2","8.8.8.8")

# --- For VM 189 (BT9-STRATCOM-WS2) ---
New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress 10.9.0.5 -PrefixLength 24 -DefaultGateway 10.9.0.1
Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses ("10.9.0.2","8.8.8.8")

# --- For VM 188 (BT9-STRATCOM-WS3) ---
New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress 10.9.0.6 -PrefixLength 24 -DefaultGateway 10.9.0.1
Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses ("10.9.0.2","8.8.8.8")
```

---

## 7. Verification Script & Live Results

Run the following verification command from `node1` to check all QGA-enabled VMs on `node2`:

```bash
ssh root@10.2.229.10 '
for vmid in 145 144 107 147 148 184 166 159 186 187 183 185; do
  name=$(qm config $vmid | awk "/^name:/ {print \$2}")
  res=$(qm guest exec $vmid -- powershell.exe -NoProfile -Command "
    \$ips = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { \$_.InterfaceAlias -notmatch \"Loopback\" } | ForEach-Object { \$_.IPAddress + \"(\" + \$_.AddressState + \")\" }) -join \",\"
    \$gw = (Get-NetRoute -DestinationPrefix \"0.0.0.0/0\" -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop
    \$p8 = Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet
    \$ns = (Resolve-DnsName -Name www.msftconnecttest.com -Type A -ErrorAction SilentlyContinue | Where-Object { \$_.IPAddress } | Select-Object -First 1).IPAddress
    Write-Output \"IP=\$ips | GW=\$gw | Ping8888=\$p8 | DNS_Resolve=\$ns\"
  " 2>/dev/null | grep "\"out-data\"" | sed "s/.*\"out-data\" : \"//;s/\".*//;s/\\\\r\\\\n//g")
  echo "VM $vmid ($name): $res"
done
'
```

### Verified Output After Applying Procedures 1 & 2

| Team | VM ID | VM Name | IPv4 Address (`State`) | Default Gateway | `Ping 8.8.8.8` | `DNS_Resolve` (`www.msftconnecttest.com`) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **BT5** | **145** | `BT5-PCG-WS1` | `10.5.0.4(Preferred)` | `10.5.0.1` | **`True`** | **`116.89.245.74`** |
| **BT5** | **144** | `BT5-PCG-WS2` | `10.5.0.5(Preferred)` | `10.5.0.1` | **`True`** | **`116.89.245.73`** |
| **BT5** | **107** | `BT5-PCG-WS3` | `10.5.0.6(Preferred)` | `10.5.0.1` | **`True`** | **`116.89.245.74`** |
| **BT6** | **147** | `BT6-DND-WS1` | `10.6.0.4(Preferred)` | `10.6.0.1` | **`True`** | **`116.89.245.74`** |
| **BT6** | **148** | `BT6-DND-WS2` | `10.6.0.5(Preferred)` | `10.6.0.1` | **`True`** | **`116.89.245.73`** |
| **BT6** | **184** | `BT6-DND-WS3` | `10.6.0.6(Preferred)` | `10.6.0.1` | **`True`** | **`116.89.245.74`** |
| **BT7** | **159** | `BT7-WESCOM-FileSvr` | `10.7.0.3(Preferred)` | `10.7.0.1` | **`True`** | **`116.89.245.74`** |
| **BT7** | **166** | `BT7-WESCOM-WS3` | `10.7.0.6(Preferred)` | `10.7.0.1` | **`True`** | **`116.89.245.73`** |
| **BT8** | **186** | `BT8-NOLCOM-WS1` | `10.8.0.4(Preferred)` | `10.8.0.1` | **`True`** | **`116.89.245.74`** |
| **BT8** | **187** | `BT8-NOLCOM-WS2` | `10.8.0.5(Preferred)` | `10.8.0.1` | **`True`** | **`116.89.245.73`** |
| **BT8** | **183** | `BT8-NOLCOM-WS3` | `10.8.0.6(Preferred)` | `10.8.0.1` | **`True`** | **`116.89.245.74`** |
| **BT9** | **185** | `BT9-STRATCOM-WS1` | `10.9.0.4(Preferred)` | `10.9.0.1` | `False` *(awaiting Procedure 3)* | `116.89.245.73` |
