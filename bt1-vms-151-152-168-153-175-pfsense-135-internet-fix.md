# Step-by-Step Guide: Fixing `TTL Expired in Transit` for BT1 VMs (151, 152, 168, 153 & 175) Through pfSense (VM 135)

This guide documents the network topology, root cause analysis, CLI & WebGUI fix procedures, and live verification steps for resolving the **`Reply from 10.1.0.1: TTL expired in transit`** error affecting **BT1 (CYCOM)** Workstations (**VM 151, VM 152, VM 168**), File Server (**VM 153**), and Domain Controller (**VM 175**) routing through **BT1-CYCOM-PFSENSE (VM 135)** on **`node1` (`10.2.229.9`)**.

---

## 1. Network Topology & BT1 Inventory

| Role | VM ID | VM Name | Interface / Bridge | IPv4 Address | Default Gateway | DNS Servers |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Upstream Core Router** | **119** | `CydexCorePfsenseNode1` | `em0` (`vmbr0`)<br>`em1` (`vmbr1`) | WAN: `10.2.229.x/24`<br>LAN: `10.100.0.1/24` | `10.2.229.1` | `8.8.8.8, 1.1.1.1` |
| **BT1 pfSense Router** | **135** | `BT1-CYCOM-PFSENSE` | `em0` (WAN, `vmbr1`)<br>`em1` (LAN, `vmbr1`) | WAN: `10.100.0.10/24`<br>LAN: `10.1.0.1/24` | `10.100.0.1` (`WANGateWay`) | `10.100.0.1, 8.8.8.8` |
| **BT1 Domain Controller** | **175** | `BT1-CYCOM-DC` | `Ethernet` (`vmbr1`)<br>`Ethernet 2` (`vmbr0`) | `10.1.0.2/24`<br>`10.2.229.95/24` | `10.1.0.1` | Forwarders: `8.8.8.8, 1.1.1.1` |
| **BT1 File Server** | **153** | `BT1-CYCOM-FileSvr` | `Ethernet` (`vmbr1`) | `10.1.0.3/24` | `10.1.0.1` | `10.1.0.2, 8.8.8.8` |
| **BT1 Workstation 1** | **151** | `BT1-CYCOM-WS1` | `Ethernet` (`vmbr1`) | `10.1.0.4/24` | `10.1.0.1` | `10.1.0.2, 8.8.8.8` |
| **BT1 Workstation 2** | **152** | `BT1-CYCOM-WS2` | `Ethernet` (`vmbr1`) | `10.1.0.9/24` | `10.1.0.1` | `10.1.0.2, 8.8.8.8` |
| **BT1 Workstation 3** | **168** | `BT1-CYCOM-WS3` | `Ethernet` (`vmbr1`) | `10.1.0.6/24` | `10.1.0.1` | `10.1.0.2, 8.8.8.8` |

---

## 2. Root Cause Analysis

### Symptom
- Pinging `8.8.8.8` from VMs `151, 152, 168, 153` succeeded, **but** pinging any other IP (`1.1.1.1`, `google.com`, or opening any HTTPS website) failed immediately with:
  ```text
  Reply from 10.1.0.1: TTL expired in transit.
  ```
- Packet captures on `vmbr1` (`tcpdump -ni vmbr1 -vvv -e 'net 10.1.0.0/24'`) showed packets arriving at `10.1.0.1` (`BC:24:11:61:E6:EB`, `em1` on **VM 135**) with `ttl 128` and **VM 135** replying `0.4ms` later with `ICMP time exceeded in-transit` (inner packet `ttl 1`) without forwarding the packet out of `em0` (`10.100.0.10`).

### Root Cause Inside `BT1-CYCOM-PFSENSE` (VM 135)
1. **Self-Referential LAN Gateway (`LANGW -> 10.1.0.1`) Set as Default Gateway**:
   - Inside `/cf/conf/config.xml` on **VM 135**, `<gateways>` contained an invalid `<gateway_item>` named `LANGW` pointing to `10.1.0.1` (pfSense's own LAN IP address) and set `<defaultgw4>LANGW</defaultgw4>` instead of `<defaultgw4>WANGateWay</defaultgw4>` (`10.100.0.1`):
     ```xml
     <gateway_item>
         <interface>lan</interface>
         <gateway>10.1.0.1</gateway>
         <name>LANGW</name>
         <descr><![CDATA[Interface lan Gateway]]></descr>
     </gateway_item>
     ...
     <gateway_item>
         <interface>wan</interface>
         <gateway>10.100.0.1</gateway>
         <name>WANGateWay</name>
     </gateway_item>
     <defaultgw4>LANGW</defaultgw4>
     ```
2. **Why `8.8.8.8` Worked While All Other Destinations Failed with `TTL expired in transit`**:
   - Before the fix, the FreeBSD routing table (`netstat -rn -f inet`) on **VM 135** was:
     ```text
     Destination        Gateway            Flags         Netif Expire
     default            10.1.0.1           UGS             em1
     8.8.8.8            10.100.0.1         UGHS            em0
     10.1.0.0/24        link#2             U               em1
     10.1.0.1           link#4             UHS             lo0
     ```
   - Because `dpinger` (Gateway Monitoring) monitored `8.8.8.8` via `10.100.0.1`, it installed a specific `/32` host route `8.8.8.8 -> 10.100.0.1 (em0)`.
   - Every other internet IP matched `default -> 10.1.0.1`, which resolved to `10.1.0.1 -> link#4 (lo0)` (loopback). Packets looped internally inside the FreeBSD kernel 127 times until the IPv4 TTL reached `1`, triggering `ICMP time exceeded in-transit` from `10.1.0.1`.
3. **Secondary Default Route on `BT1-CYCOM-DC` (VM 175)**:
   - **VM 175** had a secondary default route `0.0.0.0/0 -> 10.2.229.1` on `Ethernet 2` (`vmbr0`) with a lower metric than `10.1.0.1`, bypassing **VM 135 (`BT1-CYCOM-PFSENSE`)**.

---

## 3. Step-by-Step Fix Procedures (Applied)

### Step 1: Fix Default Gateway & Routing Table on `BT1-CYCOM-PFSENSE` (VM 135)

#### Option A: Via pfSense Shell (Console Option `8`)
Open the Proxmox noVNC Console for **VM 135 (`BT1-CYCOM-PFSENSE`)**, select **Option `8` (Shell)**, and run:

```sh
# 1. Back up config.xml
cp /cf/conf/config.xml /cf/conf/config.xml.bak

# 2. Replace defaultgw4 LANGW with WANGateWay and remove the LANGW gateway_item block (lines 389-397)
sed -i.b -e 's/LANGW/WANGateWay/' -e '389,397d' /cf/conf/config.xml

# 3. Fix the live kernel default route to point to 10.100.0.1 (CydexCorePfsenseNode1)
route delete default
route add default 10.100.0.1

# 4. Clear config cache and reload pfSense filter/NAT rules
rm -f /tmp/config.cache
/etc/rc.filter_configure_sync

# 5. Verify routing table
netstat -rn -f inet
```

#### Option B: Equivalent Steps via pfSense WebGUI (`https://10.1.0.1`)
1. Log into the pfSense WebGUI at `https://10.1.0.1`.
2. Go to **Interfaces → LAN**:
   - Ensure **IPv4 Upstream gateway** is set to **`None`**, then click **Save** and **Apply Changes**.
3. Go to **System → Routing → Gateways**:
   - Set **Default gateway IPv4** to **`WANGateWay (10.100.0.1)`**.
   - Delete the **`LANGW` (`10.1.0.1`)** gateway entry.
   - Click **Save** and **Apply Changes**.

---

### Step 2: Configure `BT1-CYCOM-DC` (VM 175) to Route Default Traffic via `PFSENSE (135)` (`10.1.0.1`)

Run the following command from the Proxmox `node1` CLI to remove the competing `0.0.0.0/0 -> 10.2.229.1` default route on **VM 175** while keeping `10.2.229.95/24` active for `10.2.229.0/24` management access:

```bash
qm guest exec 175 -- powershell.exe -NoProfile -Command '
  Set-NetIPInterface -InterfaceIndex 6 -InterfaceMetric 5
  Set-NetIPInterface -InterfaceIndex 5 -InterfaceMetric 500
  Set-NetRoute -DestinationPrefix "0.0.0.0/0" -NextHop "10.1.0.1" -RouteMetric 1 -ErrorAction SilentlyContinue
  Remove-NetRoute -DestinationPrefix "0.0.0.0/0" -NextHop "10.2.229.1" -Confirm:$false -ErrorAction SilentlyContinue
  Remove-NetRoute -DestinationPrefix "0.0.0.0/0" -NextHop "10.2.229.1" -PolicyStore PersistentStore -Confirm:$false -ErrorAction SilentlyContinue
'
```

---

### Step 3: Verify / Standardize IP, Gateway (`10.1.0.1`), and DNS (`10.1.0.2, 8.8.8.8`) on VMs 151, 152, 168 & 153

All BT1 VMs use `10.1.0.1` (`VM 135`) as their Default Gateway and `10.1.0.2` (`VM 175`) + `8.8.8.8` as DNS servers:
- **VM 151 (`BT1-CYCOM-WS1`)**: `10.1.0.4/24`, Gateway `10.1.0.1`, DNS `10.1.0.2, 8.8.8.8`
- **VM 152 (`BT1-CYCOM-WS2`)**: `10.1.0.9/24`, Gateway `10.1.0.1`, DNS `10.1.0.2, 8.8.8.8`
- **VM 168 (`BT1-CYCOM-WS3`)**: `10.1.0.6/24`, Gateway `10.1.0.1`, DNS `10.1.0.2, 8.8.8.8`
- **VM 153 (`BT1-CYCOM-FileSvr`)**: `10.1.0.3/24`, Gateway `10.1.0.1`, DNS `10.1.0.2, 8.8.8.8`
- **VM 175 (`BT1-CYCOM-DC`)**: `10.1.0.2/24`, Gateway `10.1.0.1`, Forwarders `8.8.8.8, 1.1.1.1`

---

## 4. Live Verification Results

### A. Fixed Routing Table on `BT1-CYCOM-PFSENSE` (VM 135)
```text
Destination        Gateway            Flags         Netif Expire
default            10.100.0.1         UGS             em0
8.8.8.8            10.100.0.1         UGHS            em0
10.1.0.0/24        link#2             U               em1
10.1.0.1           link#4             UHS             lo0
10.100.0.0/24      link#1             U               em0
10.100.0.10        link#4             UHS             lo0
127.0.0.1          link#4             UH              lo0
```

### B. End-to-End Connectivity & Traceroute Verification Across VMs 151, 152, 168, 153 & 175

| VM ID | VM Name | IPv4 Address | Default Gateway | Traceroute (`tracert -d -h 3 1.1.1.1`) | `ping 1.1.1.1` | `ping google.com` | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **151** | `BT1-CYCOM-WS1` | `10.1.0.4/24` | `10.1.0.1` | `10.1.0.1 → 10.100.0.1 → 10.2.229.1` | **0% loss** (`2ms`, `TTL=57`) | **0% loss** (`28ms`, `TTL=97`) | **Online** |
| **152** | `BT1-CYCOM-WS2` | `10.1.0.9/24` | `10.1.0.1` | `10.1.0.1 → 10.100.0.1 → 10.2.229.1` | **0% loss** (`2ms`, `TTL=57`) | **0% loss** (`28ms`, `TTL=97`) | **Online** |
| **168** | `BT1-CYCOM-WS3` | `10.1.0.6/24` | `10.1.0.1` | `10.1.0.1 → 10.100.0.1 → 10.2.229.1` | **0% loss** (`2ms`, `TTL=57`) | **0% loss** (`27ms`, `TTL=97`) | **Online** |
| **153** | `BT1-CYCOM-FileSvr` | `10.1.0.3/24` | `10.1.0.1` | `10.1.0.1 → 10.100.0.1 → 10.2.229.1` | **0% loss** (`2ms`, `TTL=57`) | **0% loss** (`55ms`, `TTL=97`) | **Online** |
| **175** | `BT1-CYCOM-DC` | `10.1.0.2/24` | `10.1.0.1` | `10.1.0.1 → 10.100.0.1 → 10.2.229.1` | **0% loss** (`2ms`, `TTL=57`) | **0% loss** (`29ms`, `TTL=96`) | **Online** |
