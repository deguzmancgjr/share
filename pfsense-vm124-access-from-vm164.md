# Step-by-Step Procedure: Enable SSH and WebGUI Access to pfSense (VM 124) from VM 164

## 1. Network & System Overview

| Host / VM | VM ID | Hostname / OS | Interface / Role | IP Address | Bridge |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Source** | **164** | `sysad-mngt-node2` (Windows 11) | `Ethernet` (Management) | `10.100.0.164/24` | `vmbr1` |
| **Destination** | **124** | `BT7-WESCOM-PFSENSE` (pfSense) | `em0` (WAN) | `10.100.0.70/24` | `vmbr1` |
| **Destination** | **124** | `BT7-WESCOM-PFSENSE` (pfSense) | `em1` (LAN) | `10.7.0.1/24` | `vmbr1` |

---

## 2. Root Cause Analysis

By default, pfSense treats `em0` (`10.100.0.70`) as its **WAN** interface:
1. **RFC 1918 Private Network Block (`blockpriv`)**: pfSense actively blocks all inbound traffic originating from private subnets (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) on the WAN interface using a high-priority packet filter drop rule. Because VM 164 is on `10.100.0.164`, its packets are discarded immediately.
2. **Default WAN Inbound Policy (Block All)**: Unlike the LAN interface, the WAN interface has no anti-lockout or default-allow rule. Port 22 (SSH) and Port 443 (HTTPS) are blocked unless explicitly permitted by a WAN firewall rule.

---

## 3. Solution Options

Choose **Option 1** (fastest, via Proxmox Host CLI) or **Option 2** (via pfSense Web GUI).

---

### Option 1: Fast Setup via Proxmox CLI (Recommended)

Run these commands directly from the Proxmox host terminal:

#### Step 1: Disable "Block Private Networks" on WAN
pfSense stores this under interface configuration. Execute this PHP command via the QEMU guest agent:
```bash
qm guest exec 124 -- php -r '
require_once("config.inc");
unset($config["interfaces"]["wan"]["blockpriv"]);
write_config("Disable blockpriv on WAN");
filter_configure();
'
```

#### Step 2: Add Firewall Pass Rules for VM 164
Use the built-in pfSense `easyrule` utility to allow SSH, HTTPS (WebConfigurator), and ICMP (Ping) specifically from VM 164 (`10.100.0.164`):

```bash
# Allow SSH (Port 22)
qm guest exec 124 -- /usr/local/bin/easyrule pass wan tcp 10.100.0.164 "(self)" 22

# Allow WebConfigurator HTTPS (Port 443)
qm guest exec 124 -- /usr/local/bin/easyrule pass wan tcp 10.100.0.164 "(self)" 443

# Allow Ping (ICMP)
qm guest exec 124 -- /usr/local/bin/easyrule pass wan icmp 10.100.0.164 "(self)"
```

---

### Option 2: Step-by-Step via pfSense Web GUI

If you prefer configuring through the web interface:

#### Step 1: Temporarily Unlock the Firewall
1. In Proxmox VE, click on VM **124 (`BT7-WESCOM-PFSENSE`)** and open the **Console** (`>_ Console`).
2. Press `Enter` to display the pfSense menu.
3. Type `8` and press `Enter` to enter the **Shell**.
4. Temporarily disable packet filtering:
   ```sh
   pfctl -d
   ```
   *(pfSense will print `pf disabled`. The Web GUI is now temporarily reachable from VM 164).*

#### Step 2: Uncheck "Block Private Networks"
1. Switch to **VM 164** (Windows 11).
2. Open a browser (Edge / Chrome) and go to:
   ```
   https://10.100.0.70
   ```
3. Accept the self-signed certificate warning (`Advanced` -> `Proceed to 10.100.0.70`).
4. Log in with your pfSense administrator credentials (default: `admin` / `pfsense`).
5. Navigate to **Interfaces** > **WAN** in the top navigation bar.
6. Scroll down to the bottom section: **Reserved Networks**.
7. **Uncheck** `Block private networks and loopback addresses`.
8. Click **Save** at the bottom, then click **Apply Changes** at the top.

#### Step 3: Add Firewall Pass Rules on WAN
1. In pfSense Web GUI, navigate to **Firewall** > **Rules** > **WAN** tab.
2. Click the green **Add** button (with the arrow pointing up to place it at the top).
3. Configure the rule for **SSH**:
   * **Action**: `Pass`
   * **Interface**: `WAN`
   * **Address Family**: `IPv4`
   * **Protocol**: `TCP`
   * **Source**: Select `Single host or alias` and enter: `10.100.0.164`
   * **Destination**: Select `WAN address` (or `This Firewall (self)`)
   * **Destination Port Range**:
     * From: `SSH (22)`
     * To: `SSH (22)`
   * **Description**: `Allow SSH from VM 164`
4. Click **Save**.
5. *(Optional for Web GUI access)* Click **Add** again and repeat the above with Destination Port `HTTPS (443)` and Description `Allow HTTPS from VM 164`.
6. *(Optional for Ping)* Click **Add** with Protocol `ICMP`, ICMP Subtypes `Echo request`, and Source `10.100.0.164`.
7. Click **Apply Changes** at the top of the rules list.

#### Step 4: Re-enable the Packet Filter
Return to the pfSense shell console (VM 124) and run:
```sh
pfctl -e
```
*(pfSense will print `pf enabled`).*

---

## 4. Verification from VM 164

Log into **VM 164 (`sysad-mngt-node2`)** and test connectivity:

### Test 1: Ping Test (PowerShell or CMD)
```powershell
ping 10.100.0.70
```
Expected output:
```
Reply from 10.100.0.70: bytes=32 time<1ms TTL=64
```

### Test 2: SSH Connection
Open PowerShell or Command Prompt on VM 164:
```powershell
ssh admin@10.100.0.70
```
* If prompted `Are you sure you want to continue connecting (yes/no/[fingerprint])?`, type `yes`.
* Enter the administrator password.
* You will be greeted by the pfSense menu options (1 through 16).

### Test 3: WebConfigurator Browser Access
Open a web browser on VM 164 and navigate to:
```
https://10.100.0.70
```
The pfSense login portal will load.

---

## 5. Troubleshooting Checklist

| Issue | Likely Cause | Solution |
| :--- | :--- | :--- |
| `Request timed out` on ping | "Block private networks" is still active or ICMP rule missing | Verify `blockpriv` is unchecked under Interfaces > WAN and ICMP is allowed. |
| `Connection refused` on port 22 | SSH service is disabled in pfSense | In pfSense, go to **System > Advanced > Admin Access**, check **Enable Secure Shell**, and Save. |
| `Connection timed out` on SSH | Firewall rule missing or misconfigured source IP | Ensure rule under **Firewall > Rules > WAN** specifies Source `10.100.0.164` (or `10.100.0.0/24`) and Destination Port `22`. |
| Locked out of pfSense | Packet filter blocking traffic | Open Proxmox VNC console for VM 124, choose option 8 (Shell), and run `pfctl -d` to regain immediate access. |
