# Step-by-Step Guide: Fixing Internet Connection for BT9 Workstations (VMs 185, 189 & 188) Through pfSense (VM 197)

This guide explains the exact root causes, automated CLI procedures, WebGUI procedures, and live verification steps for restoring internet access to **BT9 (STRATCOM)** Workstations (**VM 185, VM 189, and VM 188**) through **BT9-STRATCOM-PFSENSE (VM 197)** on **`node2` (`10.2.229.10`)**.

---

## 1. Network Topology & BT9 Inventory

| Role | VM ID | VM Name | Interface / Bridge | IP Address | Gateway | DNS Servers |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Upstream Core Router** | **132** | `CydexCorePfsenseN2` | `em0` (`vmbr0`) / `em1` (`vmbr1`) | WAN: `10.2.229.25/24`<br>LAN: `10.100.0.1/24` | `10.2.229.1` | `8.8.8.8, 1.1.1.1` |
| **BT9 pfSense Router** | **197** | `BT9-STRATCOM-PFSENSE` | `em0` (WAN, `vmbr1`)<br>`em1` (LAN, `vmbr1`) | WAN: `10.100.0.90/24`<br>LAN: `10.9.0.1/24` | `10.100.0.1` (`WANGW`) | `10.100.0.1, 8.8.8.8` |
| **BT9 Domain Controller** | **194** | `BT9-STRATCOM-DC` | `Ethernet` (`vmbr1`)<br>`Ethernet 2` (`vmbr0`) | `10.9.0.2/24`<br>`10.2.229.96/24` | `10.9.0.1` | Forwarders: `8.8.8.8, 1.1.1.1` |
| **BT9 Workstation 1** | **185** | `BT9-STRATCOM-WS1` | `Ethernet` (`vmbr1`) | `10.9.0.4/24` | `10.9.0.1` | `10.9.0.2, 8.8.8.8` |
| **BT9 Workstation 2** | **189** | `BT9-STRATCOM-WS2` | `Ethernet` (`vmbr1`) | `10.9.0.5/24` | `10.9.0.1` | `10.9.0.2, 8.8.8.8` |
| **BT9 Workstation 3** | **188** | `BT9-STRATCOM-WS3` | `Ethernet` (`vmbr1`) | `10.9.0.8/24` *(or `.6`)* | `10.9.0.1` | `10.9.0.2, 8.8.8.8` |

---

## 2. Root Causes Identified

Packet captures (`tcpdump -ni vmbr1 -e`) and pfSense configuration inspection (`qm guest exec 197`) revealed **three root causes** blocking internet access for VMs **185, 189, and 188**:

1. **Invalid Upstream Gateway (`LANGW`) Configured on the LAN Interface of `BT9-STRATCOM-PFSENSE` (VM 197)**:
   - Inside `/cf/conf/config.xml` on **VM 197**, the LAN interface (`em1`, `10.9.0.1/24`) had `[gateway] => LANGW` (`10.100.0.1` with `nonlocalgateway`) and `[defaultgw4] => LANGW`.
   - In pfSense, assigning an upstream gateway to a LAN interface causes two fatal issues:
     - **Broken Routing**: pfSense installs a host route `10.100.0.1 -> link#2 (em1 / LAN)`, sending all traffic destined for the upstream router `10.100.0.1` out of the LAN interface (`em1`) instead of the WAN interface (`em0`).
     - **Broken Automatic Outbound NAT**: pfSense treats any interface with an upstream gateway as a **WAN** interface rather than an internal LAN subnet, removing `10.9.0.0/24` from Outbound NAT (`pfctl -sn` only NATed `127.0.0.0/8` and omitted `10.9.0.0/24`).

2. **WAN IP Address Collision on `10.100.0.90/24` with `Kali-WhiteCellNode2` (VM 173)**:
   - **VM 173 (`Kali-WhiteCellNode2`, MAC `BC:24:11:44:9A:D7`)** was also configured with `10.100.0.90/24` on `vmbr1` — the exact WAN IP of **VM 197 (`BT9-STRATCOM-PFSENSE`, MAC `BC:24:11:3D:CB:A6`)**.
   - Whenever **VM 197** sent NATed traffic from `10.100.0.90` to `CydexCorePfsenseN2` (`10.100.0.1`), `10.100.0.1` sent the return packets (`SYN-ACK` / `ICMP Echo Reply`) to **VM 173 (`BC:24:11:44:9A:D7`)**, which immediately aborted every connection with a TCP `RST` (`[R]`).

3. **Domain Controller DNS Firewall & Workstation Secondary IP Cleanup**:
   - **VM 185 (`BT9-STRATCOM-WS1`)** held 4 IPv4 addresses simultaneously (`10.9.0.4, 10.9.0.7, 10.9.0.9, 10.9.0.13`).
   - **VM 194 (`BT9-STRATCOM-DC`, `10.9.0.2`)** required inbound Windows Firewall rules (`UDP/TCP 53` on `Profile: Any`) and public DNS forwarders (`8.8.8.8, 1.1.1.1`).

---

## 3. Step-by-Step Fix Procedures (Already Applied)

### Step 1: Fix `BT9-STRATCOM-PFSENSE` (VM 197) LAN Gateway, Default Route & Outbound NAT

#### Option A: Via Proxmox Host CLI on `node2` (`qm guest exec`)
Run the following commands on `node2` (`10.2.229.10`):

```bash
# 1. Remove LANGW from LAN interface, set defaultgw4 to WANGW, and disable blockpriv on WAN
qm guest exec 197 -- /usr/local/bin/php -r '
require_once("config.inc");

unset($config["interfaces"]["lan"]["gateway"]);

if (isset($config["gateways"]["gateway_item"]) && is_array($config["gateways"]["gateway_item"])) {
    foreach ($config["gateways"]["gateway_item"] as $idx => $gw) {
        if (isset($gw["name"]) && $gw["name"] === "LANGW") {
            unset($config["gateways"]["gateway_item"][$idx]);
        }
    }
    $config["gateways"]["gateway_item"] = array_values($config["gateways"]["gateway_item"]);
}
$config["gateways"]["defaultgw4"] = "WANGW";
unset($config["interfaces"]["wan"]["blockpriv"]);

write_config("Remove invalid LANGW on LAN and set defaultgw4 to WANGW");
'

# 2. Clean kernel routing table, restart gateway monitor, and reload pfSense NAT/filter
qm guest exec 197 -- /bin/sh -c '
  killall dpinger 2>/dev/null
  route delete -host 10.100.0.1 2>/dev/null
  route delete default 2>/dev/null
  route add default 10.100.0.1
  /etc/rc.filter_configure_sync
  /usr/local/bin/php -r "require_once(\"config.inc\"); require_once(\"gwlb.inc\"); setup_gateways_monitor();"
'
```

#### Option B: Equivalent Steps in the pfSense WebGUI (`https://10.9.0.1`)
1. From a BT9 workstation (`185, 189, or 188`), open `https://10.9.0.1` in a browser and log into pfSense.
2. Go to **Interfaces → LAN**:
   - Scroll to **IPv4 Upstream gateway** and change it from `LANGW - 10.100.0.1` to **`None`**.
   - Click **Save** and **Apply Changes**.
3. Go to **System → Routing → Gateways**:
   - Under **Default gateway**, set **Default gateway IPv4** to **`WANGW (10.100.0.1)`**.
   - Delete the **`LANGW`** gateway entry pointing to `LAN`.
   - Click **Save** and **Apply Changes**.
4. Go to **Firewall → NAT → Outbound**:
   - Confirm Outbound NAT Mode is set to **Automatic outbound NAT rule generation** and that `10.9.0.0/24` is listed under Automatic Rules for `WAN`.

---

### Step 2: Resolve the `10.100.0.90` WAN IP Collision with `Kali-WhiteCellNode2` (VM 173)

Re-address **VM 173 (`Kali-WhiteCellNode2`)** from `10.100.0.90/24` to `10.100.0.173/24` on `node2` so **VM 197 (`BT9-STRATCOM-PFSENSE`)** has exclusive ownership of `10.100.0.90/24`:

```bash
# 1. Change VM 173 IP from 10.100.0.90/24 to 10.100.0.173/24
qm guest exec 173 -- /bin/sh -c '
  nmcli connection modify "Wired connection 1" ipv4.addresses 10.100.0.173/24 ipv4.gateway 10.100.0.1 ipv4.dns "10.100.0.1 8.8.8.8" ipv4.method manual
  nmcli connection up "Wired connection 1"
'

# 2. Send Gratuitous ARP from VM 197 (BT9-STRATCOM-PFSENSE) so 10.100.0.1 updates its ARP cache
qm guest exec 197 -- /bin/sh -c '
  ifconfig em0 10.100.0.90/24
  route add default 10.100.0.1 2>/dev/null
  ping -c 3 -W 1 10.100.0.1
'
```

---

### Step 3: Ensure Workstation IP, Gateway (`10.9.0.1`), and DNS (`10.9.0.2, 8.8.8.8`) on VMs 185, 189 & 188

- **VM 185 (`BT9-STRATCOM-WS1`, `10.9.0.4`)**, **VM 189 (`BT9-STRATCOM-WS2`, `10.9.0.5`)**, and **VM 188 (`BT9-STRATCOM-WS3`, `10.9.0.8`)** are already configured with Default Gateway `10.9.0.1` and are actively routing through **VM 197 (`BT9-STRATCOM-PFSENSE`)**.
- If you ever need to reset or standardize the IP/Gateway/DNS inside **VM 185, 189, or 188** via PowerShell (Admin):
  ```powershell
  $ifIndex = (Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1).ifIndex
  Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
  Get-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

  # Use 10.9.0.4 for VM 185, 10.9.0.5 for VM 189, and 10.9.0.6 (or 10.9.0.8) for VM 188:
  New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress 10.9.0.4 -PrefixLength 24 -DefaultGateway 10.9.0.1
  Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses ("10.9.0.2","8.8.8.8")
  ipconfig /flushdns
  ```

---

## 4. Live Verification Results

### A. Outbound NAT & Routing Table on `BT9-STRATCOM-PFSENSE` (VM 197)
```text
Destination        Gateway            Flags         Netif Expire
default            10.100.0.1         UGS             em0
10.9.0.0/24        link#2             U               em1
10.100.0.0/24      link#1             U               em0

nat on em0 inet from 10.9.0.0/24 to any port = isakmp -> 10.100.0.90 static-port
nat on em0 inet from 10.9.0.0/24 to any -> 10.100.0.90 port 1024:65535
```

### B. Active Established Internet Sessions Through `BT9-STRATCOM-PFSENSE` (`pfctl -ss`)
All three workstations (**VM 185 `10.9.0.4`**, **VM 189 `10.9.0.5`**, and **VM 188 `10.9.0.8`**) have verified `ESTABLISHED:ESTABLISHED` outbound NAT sessions through `10.100.0.90`:
```text
# VM 185 (10.9.0.4):
em0 tcp 10.100.0.90:47576 (10.9.0.4:51491) -> 172.172.255.216:443       ESTABLISHED:ESTABLISHED
em0 tcp 10.100.0.90:20216 (10.9.0.4:51479) -> 198.41.192.107:7844       ESTABLISHED:ESTABLISHED

# VM 189 (10.9.0.5):
em0 tcp 10.100.0.90:1339  (10.9.0.5:62638) -> 172.172.255.216:443       ESTABLISHED:ESTABLISHED
em0 tcp 10.100.0.90:5377  (10.9.0.5:62645) -> 198.41.200.233:7844       ESTABLISHED:ESTABLISHED

# VM 188 (10.9.0.8):
em0 tcp 10.100.0.90:35034 (10.9.0.8:26067) -> 172.172.255.216:443       ESTABLISHED:ESTABLISHED
em0 tcp 10.100.0.90:36211 (10.9.0.8:26089) -> 198.41.200.73:7844        ESTABLISHED:ESTABLISHED
```

### C. Direct Connectivity Test from `VM 185 (BT9-STRATCOM-WS1)`
```text
Ping 10.9.0.1: True
Ping 10.100.0.1: True
Ping 8.8.8.8: True
DNS google.com: 172.217.26.238
HTTP/1.1 200 OK
```
