# Step-by-Step Guide: Adding Workstations (VMs 107, 166, 182, 183) to Domain BT6-DND-DC-138 (`dnd.local`)

This document provides complete, verified procedures for joining the 4 Windows workstation virtual machines in the BT6 environment to the Active Directory Domain Controller **BT6-DND-DC (VM 138)**.

---

## 1. Network & Infrastructure Overview

| VM ID | Proxmox Name | Target Hostname | IPv4 Address | Gateway | Primary DNS | Assigned AD User | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **138** | `BT6-DND-DC` | `WIN-NKNHGGC1IJE` | `10.2.229.78/24` | `10.2.229.1` | `127.0.0.1` | `dnd\Administrator` | Domain Controller |
| **118** | `BT6-DISGDNDCYCOM-PFSENSE` | pfSense Router | `10.6.0.1` (LAN) / `10.100.0.60` (WAN) | Upstream | — | — | Gateway / Firewall |
| **107** | `BT6-DISGDNDCYCOM-WS1` | `BT6-WS1` | `10.6.0.4/24` | `10.6.0.1` | **`10.2.229.78`** | `dnd\BT6-User1` | Workstation 1 |
| **166** | `BT6-DISGDNDCYCOM-WS2` | `BT6-WS2` | `10.6.0.5/24` | `10.6.0.1` | **`10.2.229.78`** | `dnd\BT6-User2` | Workstation 2 |
| **182** | `BT6-DISGDNDCYCOM-WS3` | `BT6-WS3` | `10.6.0.6/24` | `10.6.0.1` | **`10.2.229.78`** | `dnd\BT6-User3` | Workstation 3 |
| **183** | `BT6-DISGDNDCYCOM-WS4` | `BT6-WS4` | `10.6.0.7/24` | `10.6.0.1` | **`10.2.229.78`** | `dnd\BT6-User4` | Workstation 4 |

### Active Directory Parameters
* **Domain FQDN**: `dnd.local`
* **NetBIOS Name**: `DND`
* **Domain Controller Hostname**: `WIN-NKNHGGC1IJE.dnd.local`
* **Domain Controller IP**: `10.2.229.78`
* **Domain Admin Account**: `dnd\Administrator`

---

## 2. Key Prerequisites & Discovered Pitfalls

### Pitfall 1: DNS Server Must Point to the Domain Controller
Active Directory relies on SRV records registered in DNS. By default, VM 107 has its DNS set to `10.6.0.2` and `8.8.8.8`. These servers cannot resolve `dnd.local` and will cause domain joins to fail with error `DNS name does not exist`.
* **Fix**: The workstation's primary DNS must be configured to **`10.2.229.78`** (the DC's IP).

### Pitfall 2: VM 107 is Currently Bound to an Orphaned Domain (`viscom.local`)
VM 107 is currently joined to `viscom.local` (error code 1789 trust failure), and its local built-in `Administrator` account is disabled (`BT1-User1` is the active local admin).
* **Fix**:
  1. Enable the built-in local `Administrator` account and set a strong local password first so you never get locked out.
  2. Force-unjoin from `viscom.local` to `WORKGROUP` and reboot.
  3. Rename the workstation to its proper name (`BT6-WS1`).
  4. Join `dnd.local`.

### Pitfall 3: Sequential Boot for Cloned VMs (166, 182, 183)
VMs 166, 182, and 183 are stopped clones. If started simultaneously before configuration, they may conflict on IP `10.6.0.4` and hostname `DESKTOP-01`.
* **Fix**: Start and configure them sequentially (or configure network before starting if using cloud-init).

---

## 3. Method 1: Automated Execution via Proxmox Host CLI (Recommended)

You can perform the entire operation directly from the Proxmox host terminal using `qm guest exec`. This requires no manual desktop clicking.

### Step 3.1: Prepare VM 107 (Unjoin Stale Domain & Set DNS)

Run the following commands directly on the Proxmox host terminal:

```bash
# 1. Enable local Administrator and set password (avoids lockout)
qm guest exec 107 powershell.exe -- -Command '
Enable-LocalUser -Name "Administrator"
$Password = ConvertTo-SecureString "P@ssw0rd2026!" -AsPlainText -Force
Set-LocalUser -Name "Administrator" -Password $Password
'

# 2. Set Primary DNS to the Domain Controller (10.2.229.78)
qm guest exec 107 powershell.exe -- -Command '
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses ("10.2.229.78", "10.6.0.1")
'

# 3. Unjoin from old stale domain viscom.local into WORKGROUP and rename to BT6-WS1
qm guest exec 107 powershell.exe -- -Command '
Remove-Computer -Force
Rename-Computer -NewName "BT6-WS1" -Force
Restart-Computer -Force
'
```

*Wait approximately 30–45 seconds for VM 107 to reboot.*

### Step 3.2: Join VM 107 to `dnd.local`

Once VM 107 has rebooted, execute the domain join command from the Proxmox host (replace `<DOMAIN_ADMIN_PASSWORD>` with your `dnd\Administrator` password):

```bash
qm guest exec 107 powershell.exe -- -Command '
$Domain = "dnd.local"
$User = "dnd\Administrator"
$Password = ConvertTo-SecureString "<DOMAIN_ADMIN_PASSWORD>" -AsPlainText -Force
$Cred = New-Object System.Management.Automation.PSCredential($User, $Password)

# Join the domain and reboot
Add-Computer -DomainName $Domain -Credential $Cred -Restart -Force
'
```

*Wait approximately 45 seconds for VM 107 to reboot into the domain.*

### Step 3.3: Assign Lab Domain User (`BT6-User1`)

After VM 107 is in the domain, grant the user Remote Desktop and Local Administrator rights:

```bash
qm guest exec 107 powershell.exe -- -Command '
Add-LocalGroupMember -Group "Remote Desktop Users" -Member "DND\BT6-User1"
Add-LocalGroupMember -Group "Administrators" -Member "DND\BT6-User1"
'
```

---

### Step 3.4: Repeat for VMs 166, 182, and 183

For each of the remaining VMs, power them on one at a time and apply their unique configuration:

#### A. VM 166 (`BT6-WS2` - IP `10.6.0.5`):
```bash
# 1. Start VM 166
qm start 166
sleep 45

# 2. Set Static IP and DNS
qm guest exec 166 powershell.exe -- -Command '
New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress "10.6.0.5" -PrefixLength 24 -DefaultGateway "10.6.0.1" -ErrorAction SilentlyContinue
Set-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress "10.6.0.5" -PrefixLength 24 -ErrorAction SilentlyContinue
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses ("10.2.229.78", "10.6.0.1")
Enable-LocalUser -Name "Administrator" -ErrorAction SilentlyContinue
Rename-Computer -NewName "BT6-WS2" -Force
Restart-Computer -Force
'
sleep 45

# 3. Join to dnd.local
qm guest exec 166 powershell.exe -- -Command '
$Cred = New-Object System.Management.Automation.PSCredential("dnd\Administrator", (ConvertTo-SecureString "<DOMAIN_ADMIN_PASSWORD>" -AsPlainText -Force))
Add-Computer -DomainName "dnd.local" -Credential $Cred -Restart -Force
'
sleep 45

# 4. Add User Permission
qm guest exec 166 powershell.exe -- -Command '
Add-LocalGroupMember -Group "Remote Desktop Users" -Member "DND\BT6-User2"
Add-LocalGroupMember -Group "Administrators" -Member "DND\BT6-User2"
'
```

#### B. VM 182 (`BT6-WS3` - IP `10.6.0.6`):
```bash
# 1. Optional: Rename Proxmox display name from WS2 to WS3
qm set 182 --name "BT6-DISGDNDCYCOM-WS3"

# 2. Start VM 182
qm start 182
sleep 45

# 3. Set Static IP and DNS
qm guest exec 182 powershell.exe -- -Command '
New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress "10.6.0.6" -PrefixLength 24 -DefaultGateway "10.6.0.1" -ErrorAction SilentlyContinue
Set-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress "10.6.0.6" -PrefixLength 24 -ErrorAction SilentlyContinue
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses ("10.2.229.78", "10.6.0.1")
Enable-LocalUser -Name "Administrator" -ErrorAction SilentlyContinue
Rename-Computer -NewName "BT6-WS3" -Force
Restart-Computer -Force
'
sleep 45

# 4. Join to dnd.local
qm guest exec 182 powershell.exe -- -Command '
$Cred = New-Object System.Management.Automation.PSCredential("dnd\Administrator", (ConvertTo-SecureString "<DOMAIN_ADMIN_PASSWORD>" -AsPlainText -Force))
Add-Computer -DomainName "dnd.local" -Credential $Cred -Restart -Force
'
sleep 45

# 5. Add User Permission
qm guest exec 182 powershell.exe -- -Command '
Add-LocalGroupMember -Group "Remote Desktop Users" -Member "DND\BT6-User3"
Add-LocalGroupMember -Group "Administrators" -Member "DND\BT6-User3"
'
```

#### C. VM 183 (`BT6-WS4` - IP `10.6.0.7`):
```bash
# 1. Start VM 183
qm start 183
sleep 45

# 2. Set Static IP and DNS
qm guest exec 183 powershell.exe -- -Command '
New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress "10.6.0.7" -PrefixLength 24 -DefaultGateway "10.6.0.1" -ErrorAction SilentlyContinue
Set-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress "10.6.0.7" -PrefixLength 24 -ErrorAction SilentlyContinue
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses ("10.2.229.78", "10.6.0.1")
Enable-LocalUser -Name "Administrator" -ErrorAction SilentlyContinue
Rename-Computer -NewName "BT6-WS4" -Force
Restart-Computer -Force
'
sleep 45

# 3. Join to dnd.local
qm guest exec 183 powershell.exe -- -Command '
$Cred = New-Object System.Management.Automation.PSCredential("dnd\Administrator", (ConvertTo-SecureString "<DOMAIN_ADMIN_PASSWORD>" -AsPlainText -Force))
Add-Computer -DomainName "dnd.local" -Credential $Cred -Restart -Force
'
sleep 45

# 4. Add User Permission
qm guest exec 183 powershell.exe -- -Command '
Add-LocalGroupMember -Group "Remote Desktop Users" -Member "DND\BT6-User4"
Add-LocalGroupMember -Group "Administrators" -Member "DND\BT6-User4"
'
```

---

## 4. Method 2: Manual GUI Procedure (Inside Windows Desktop)

If you are logged into each Windows workstation via Guacamole or Proxmox Console:

### Step 4.1: Configure Network & DNS
1. Press `Win + R`, type `ncpa.cpl`, and press **Enter**.
2. Right-click **Ethernet** > **Properties**.
3. Double-click **Internet Protocol Version 4 (TCP/IPv4)**.
4. Set:
   * **IP Address**: e.g. `10.6.0.4` (for WS1)
   * **Subnet mask**: `255.255.255.0`
   * **Default gateway**: `10.6.0.1`
   * **Preferred DNS server**: **`10.2.229.78`**
   * **Alternate DNS server**: `10.6.0.1`
5. Click **OK** > **OK**.

### Step 4.2: Verify Reachability via PowerShell
Open PowerShell as Administrator and run:
```powershell
Resolve-DnsName dnd.local
Test-NetConnection -ComputerName 10.2.229.78 -Port 389
```
*Both tests must succeed.*

### Step 4.3: Change Computer Name and Join Domain
1. Press `Win + R`, type `sysdm.cpl`, and press **Enter** (opens System Properties).
2. On the **Computer Name** tab, click **Change...**.
3. Under **Computer name**, set the standard name (e.g., `BT6-WS1`).
4. Under **Member of**, select **Domain** and type:
   ```
   dnd.local
   ```
5. Click **OK**.
6. When prompted for credentials, enter:
   * **User name**: `dnd\Administrator` (or `Administrator@dnd.local`)
   * **Password**: `<DOMAIN_ADMIN_PASSWORD>`
7. Click **OK**.
8. A prompt will appear: `"Welcome to the dnd.local domain."` Click **OK**.
9. Click **Close** and select **Restart Now**.

### Step 4.4: Login with Domain User
After rebooting:
1. Select **Other user**.
2. Sign in with:
   * **Username**: `dnd\BT6-User1` (or `BT6-User1@dnd.local`)
   * **Password**: Password configured in Active Directory for `BT6-User1`.

---

## 5. Verification & Health Checks

From the Proxmox host terminal, verify all workstations in Active Directory and on the workstations:

### 1. Check Active Directory Registered Computers (on DC 138)
```bash
qm guest exec 138 powershell.exe -- -Command "Get-ADComputer -Filter * | Select-Object Name, DNSHostName, IPv4Address, Enabled"
```
**Expected Output**:
```
Name      DNSHostName            IPv4Address Enabled
----      -----------            ----------- -------
WIN-NK... WIN-NKNHGGC1IJE...     10.2.229.78    True
BT6-WS1   BT6-WS1.dnd.local      10.6.0.4       True
BT6-WS2   BT6-WS2.dnd.local      10.6.0.5       True
BT6-WS3   BT6-WS3.dnd.local      10.6.0.6       True
BT6-WS4   BT6-WS4.dnd.local      10.6.0.7       True
```

### 2. Verify Secure Channel on Each Workstation
```bash
for vmid in 107 166 182 183; do
  echo "=== VM $vmid Secure Channel ==="
  qm guest exec $vmid powershell.exe -- -Command "Test-ComputerSecureChannel -Verbose"
done
```
**Expected Output**: `True`

---

## 6. Troubleshooting Common Issues

| Issue / Error | Root Cause | Solution |
| :--- | :--- | :--- |
| `DNS name does not exist` | DNS is pointing to an external or local router DNS that cannot resolve `dnd.local`. | Change Preferred DNS to `10.2.229.78` using `Set-DnsClientServerAddress`. |
| `The trust relationship between this workstation and the primary domain failed` | VM was previously joined to another domain (e.g. `viscom.local`). | Run `Remove-Computer -Force -Restart` before joining `dnd.local`. Ensure a local admin account is active first. |
| `Access is denied` during domain join | Incorrect domain administrator username or password. | Ensure username format is `dnd\Administrator` or `Administrator@dnd.local`. |
| `The RPC server is unavailable` | Network firewall or routing blocking DC traffic. | Verify pfSense passes port 135, 389, 445, 88, 53 to `10.2.229.78`. (Confirmed open in test). |
| `A computer account with that name already exists` | A previous computer was joined with the same name. | Run `Remove-ADComputer -Identity <Name>` on DC 138, or use `-Force` in `Add-Computer`. |
