# Detailed Guide & Procedures: Fixing Internet Access for `node1` Workstations

This guide documents the network architecture, root causes, and step-by-step procedures to restore and verify internet access and DNS resolution for all Blue Team Workstations (`151, 152, 168, 139, 140, 176, 141, 142, 128, 143, 146, 178`, plus BT5 `145, 144, 181`) on **`node1` (`10.2.229.9`)**.

---

## 1. Network Architecture & Inventory on `node1` (`10.2.229.9`)

Every Blue Team on `node1` (`BT1` through `BT4`) operates inside a logical `/24` subnet (`10.<team>.0.0/24`) attached to the Proxmox internal bridge **`vmbr1`**. Traffic routes from each Workstation (`.4, .5, .6`) through its team pfSense LAN gateway (`10.<team>.0.1`), across the `10.100.0.0/24` transit subnet to **`CydexCorePfsenseNode1` (VM 119, `10.100.0.1`)**, and out to the external network (`vmbr0`, `10.2.229.1`).

| Team | Domain | pfSense Router (LAN / WAN) | Domain Controller (`.2`) | Workstations on `node1` | Current Status |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **BT1 (CYCOM)** | `cycom.local` | **VM 201** (`10.1.0.1` / `10.100.0.10`) | **VM 175** (`10.1.0.2`) | **151** (`10.1.0.4`), **152** (`10.1.0.9`), **168** (`10.1.0.6`) | **100% Online** (Joined to `cycom.local`, Ping & DNS working) |
| **BT2 (PA)** | `pa.local` | **VM 202** (`10.2.0.1` / `10.100.0.20`) | **VM 169** (`10.2.0.2`) | **139** (`10.2.0.4`), **140** (`10.2.0.5`), **176** (`10.2.0.6`) | **100% Online** (Ping & DNS working) |
| **BT3 (PN)** | `pn.local` | **VM 203** (`10.3.0.1` / `10.100.0.30`) | **VM 192** (`10.3.0.2`) | **141** (`10.3.0.4`), **142** (`10.3.0.5`), **128** (`10.3.0.6`) | **100% Online** (Ping & DNS working) |
| **BT4 (PAF)** | `paf.local` | **VM 204** (`10.4.0.1` / `10.100.0.40`) | **VM 136** (`10.4.0.2`) | **143** (`10.4.0.4`), **146** (`10.4.0.5`), **178** (`10.4.0.6`) | **100% Online** (Ping & DNS working) |
| **BT5 (PCG)** | `pcg.local` | Hosted on `node2` (**VM 212**) | Hosted on `node2` (**VM 214**) | **181** (stopped copy on `node1`); active **145, 144, 107** run on `node2` | Managed on `node2` |

---

## 2. Root Causes Identified & Fixed on `node1`

1. **Wrong Proxmox Bridge on VM 151 (`BT1-CYCOM-WS1`)**:
   - `net0` on **VM 151** was attached to `vmbr0` instead of `vmbr1`, isolating it from `BT1-CYCOM-DC` (`10.1.0.2`) and `BT1-CYCOM-PFSENSE` (`10.1.0.1`).
   - **Fix**: Moved `net0` to `vmbr1` (`qm set 151 -net0 e1000=BC:24:11:1B:63:4B,bridge=vmbr1,firewall=1`).
2. **Duplicate IP on VM 168 (`BT1-CYCOM-WS3`)**:
   - **VM 168** held both `10.1.0.6` and `10.1.0.9` (colliding with **VM 152**).
   - **Fix**: Removed `10.1.0.9` from **VM 168**, leaving `10.1.0.6/24`.
3. **Domain Controller Windows Firewall & Forwarders (`175, 169, 192, 136`)**:
   - Internal `vmbr1` NICs on the Domain Controllers booted under the `Private` firewall profile, blocking UDP/TCP 53 from workstations, and only forwarded to `10.2.196.11` / `10.2.196.12`.
   - **Fix**: Added `8.8.8.8` and `1.1.1.1` to DNS forwarders and added inbound firewall rules `Allow-DNS-Inbound-All` (UDP/TCP 53, `Profile: Any`) across all 4 `node1` DCs (`175, 169, 192, 136`).

---

## 3. Automated Fix Commands on `node1` (APPLIED)

### Step 1: Configure DNS Forwarders & Firewall Rules on `node1` DCs (`175, 169, 192, 136`)

```bash
for dcid in 175 169 192 136; do
  echo "=== Configuring DNS Forwarders & Firewall on DC VM $dcid ==="
  qm guest exec $dcid -- powershell.exe -NoProfile -Command '
    dnscmd . /ResetForwarders 8.8.8.8 1.1.1.1 10.2.196.11 10.2.196.12 /TimeOut 3
    if (-not (Get-NetFirewallRule -Name "Allow-DNS-Inbound-All" -ErrorAction SilentlyContinue)) {
      New-NetFirewallRule -Name "Allow-DNS-Inbound-All" -DisplayName "Allow DNS Inbound All Profiles" -Direction Inbound -Protocol UDP -LocalPort 53 -Action Allow -Profile Any | Out-Null
      New-NetFirewallRule -Name "Allow-DNS-TCP-Inbound-All" -DisplayName "Allow DNS TCP Inbound All Profiles" -Direction Inbound -Protocol TCP -LocalPort 53 -Action Allow -Profile Any | Out-Null
    }
    Clear-DnsServerCache -Force -ErrorAction SilentlyContinue
  '
done
```

### Step 2: Standardize Workstation IP, Default Gateway, and DNS on `node1`

```bash
set_ws_net() {
  local vmid=$1
  local ip=$2
  local gw=$3
  local dns1=$4
  local dns2=$5
  qm guest exec $vmid -- powershell.exe -NoProfile -Command "
    \$ifIndex = (Get-NetAdapter | Where-Object { \$_.Status -eq 'Up' } | Select-Object -First 1).ifIndex
    Get-NetIPAddress -InterfaceIndex \$ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:\$false -ErrorAction SilentlyContinue
    Get-NetRoute -InterfaceIndex \$ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:\$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceIndex \$ifIndex -IPAddress '$ip' -PrefixLength 24 -DefaultGateway '$gw' -ErrorAction SilentlyContinue | Out-Null
    Set-DnsClientServerAddress -InterfaceIndex \$ifIndex -ServerAddresses ('$dns1','$dns2')
    ipconfig /flushdns | Out-Null
  "
}

# BT1 (CYCOM)
set_ws_net 151 10.1.0.4 10.1.0.1 10.1.0.2 8.8.8.8
set_ws_net 152 10.1.0.9 10.1.0.1 10.1.0.2 8.8.8.8
set_ws_net 168 10.1.0.6 10.1.0.1 10.1.0.2 8.8.8.8

# BT2 (PA)
set_ws_net 139 10.2.0.4 10.2.0.1 10.2.0.2 8.8.8.8
set_ws_net 140 10.2.0.5 10.2.0.1 10.2.0.2 8.8.8.8
set_ws_net 176 10.2.0.6 10.2.0.1 10.2.0.2 8.8.8.8

# BT3 (PN)
set_ws_net 141 10.3.0.4 10.3.0.1 10.3.0.2 8.8.8.8
set_ws_net 142 10.3.0.5 10.3.0.1 10.3.0.2 8.8.8.8
set_ws_net 128 10.3.0.6 10.3.0.1 10.3.0.2 8.8.8.8

# BT4 (PAF)
set_ws_net 143 10.4.0.4 10.4.0.1 10.4.0.2 8.8.8.8
set_ws_net 146 10.4.0.5 10.4.0.1 10.4.0.2 8.8.8.8
set_ws_net 178 10.4.0.6 10.4.0.1 10.4.0.2 8.8.8.8
```

---

## 4. Verification Results Across All 12 `node1` Workstations

| Team | VM ID | VM Name | IPv4 Address | Default Gateway | `Ping 8.8.8.8` | `DNS_Resolve` (`www.msftconnecttest.com`) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **BT1** | **151** | `BT1-CYCOM-WS1` | `10.1.0.4` | `10.1.0.1` | **`True`** | **`True`** |
| **BT1** | **152** | `BT1-CYCOM-WS2` | `10.1.0.9` | `10.1.0.1` | **`True`** | **`True`** |
| **BT1** | **168** | `BT1-CYCOM-WS3` | `10.1.0.6` | `10.1.0.1` | **`True`** | **`True`** |
| **BT2** | **139** | `BT2-PA-WS1` | `10.2.0.4` | `10.2.0.1` | **`True`** | **`True`** |
| **BT2** | **140** | `BT2-PA-WS2` | `10.2.0.5` | `10.2.0.1` | **`True`** | **`True`** |
| **BT2** | **176** | `BT2-PA-WS3` | `10.2.0.6` | `10.2.0.1` | **`True`** | **`True`** |
| **BT3** | **141** | `BT3-PN-WS1` | `10.3.0.4` | `10.3.0.1` | **`True`** | **`True`** |
| **BT3** | **142** | `BT3-PN-WS2` | `10.3.0.5` | `10.3.0.1` | **`True`** | **`True`** |
| **BT3** | **128** | `BT3-PN-WS3` | `10.3.0.6` | `10.3.0.1` | **`True`** | **`True`** |
| **BT4** | **143** | `BT4-PAF-WS1` | `10.4.0.4` | `10.4.0.1` | **`True`** | **`True`** |
| **BT4** | **146** | `BT4-PAF-WS2` | `10.4.0.5` | `10.4.0.1` | **`True`** | **`True`** |
| **BT4** | **178** | `BT4-PAF-WS3` | `10.4.0.6` | `10.4.0.1` | **`True`** | **`True`** |
