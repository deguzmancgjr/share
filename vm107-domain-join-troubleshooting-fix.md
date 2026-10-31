# Troubleshooting & Resolution: Joining VM 107 (`BT6-WS1`) to Domain Controller (`dnd.local`)

## 1. Issue Description & Symptoms

When attempting to join workstation **VM 107 (`BT6-WS1`)** to the domain, Windows returns the following error:
> *"An Active Directory Domain Controller (AD DC) for the domain could not be contacted. Ensure that the domain name is typed correctly."*

---

## 2. Root Cause Analysis

Active Directory domain discovery does not rely on simple ping or IP broadcasts. Instead, Windows uses **DNS SRV Locator Records** (`_ldap._tcp.dc._msdcs.<domain>`) to locate domain controllers.

Two issues caused this error on VM 107:

1. **Incorrect DNS Server Configuration (Primary Blocker)**:
   * **Problem**: VM 107 was configured with DNS servers `10.6.0.2` and `8.8.8.8`. Neither of these servers is authoritative for your internal Active Directory zone. When VM 107 queried `dnd.local`, it returned `DNS_ERROR_RCODE_NAME_ERROR` (`DNS name does not exist`).
   * **Resolution**: The workstation's Primary DNS must point to the Active Directory Domain Controller: **`10.2.229.78`** (`BT6-DND-DC`).
2. **Domain Name Syntax**:
   * **Problem**: Attempting to join `BT6-DND-DC-138` (the Proxmox VM name) instead of the actual Active Directory Fully Qualified Domain Name (FQDN).
   * **Resolution**: The domain name to enter is **`dnd.local`** (or NetBIOS name `DND`).

---

## 3. Current System Status & Verification

VM 107's network adapter has been updated to point to DNS **`10.2.229.78`**.

### DC Discovery Verification (`nltest`)
Executing `nltest /dsgetdc:dnd.local` on VM 107 now confirms full discovery of the Domain Controller:

```text
           DC: \\WIN-NKNHGGC1IJE.dnd.local
      Address: \\10.2.229.78
     Dom Guid: 783a30c0-4e1f-4226-ab85-1ab1d86c6540
     Dom Name: dnd.local
  Forest Name: dnd.local
 Dc Site Name: Default-First-Site-Name
Our Site Name: Default-First-Site-Name
        Flags: PDC GC DS LDAP KDC TIMESERV GTIMESERV WRITABLE DNS_DC DNS_DOMAIN DNS_FOREST CLOSE_SITE FULL_SECRET WS DS_8 DS_9 DS_10 KEYLIST
The command completed successfully
```

---

## 4. Step-by-Step Procedures to Join the Domain

Choose one of the following three methods:

### Method 1: Via Windows GUI (on VM 107)

1. Open the System Properties dialog:
   * Press <kbd>Win</kbd> + <kbd>R</kbd>, type **`sysdm.cpl`**, and press **Enter**.
2. Under the **Computer Name** tab, click the **Change...** button.
3. In the *Computer Name/Domain Changes* window:
   * **Computer name**: Ensure it is set to `BT6-WS1`.
   * Under **Member of**, select **Domain** and type:
     ```
     dnd.local
     ```
4. Click **OK**.
5. When prompted for credentials, enter:
   * **User name**: `dnd\Administrator` (or `Administrator@dnd.local`)
   * **Password**: `<YOUR_DOMAIN_ADMIN_PASSWORD>`
6. Click **OK**.
7. You will see the confirmation popup:
   > *"Welcome to the dnd.local domain."*
8. Click **OK**, click **Close**, and select **Restart Now**.

---

### Method 2: Via PowerShell Inside VM 107

1. Right-click the Windows Start menu and select **Windows PowerShell (Admin)**.
2. Run the following command:
   ```powershell
   Add-Computer -DomainName "dnd.local" -Credential (Get-Credential) -Restart -Force
   ```
3. In the Windows Security popup, enter:
   * **User name**: `dnd\Administrator`
   * **Password**: `<YOUR_DOMAIN_ADMIN_PASSWORD>`
4. The VM will join the domain and automatically restart into `dnd.local`.

---

### Method 3: Automated from Proxmox Host Terminal (CLI)

You can execute the entire domain join non-interactively directly from the Proxmox host shell without opening the VM console:

```bash
qm guest exec 107 powershell.exe -- -Command '
$Domain = "dnd.local"
$User   = "dnd\Administrator"
$Pass   = ConvertTo-SecureString "<YOUR_DOMAIN_ADMIN_PASSWORD>" -AsPlainText -Force
$Cred   = New-Object System.Management.Automation.PSCredential($User, $Pass)

Add-Computer -DomainName $Domain -Credential $Cred -Restart -Force
'
```

*(Replace `<YOUR_DOMAIN_ADMIN_PASSWORD>` with the actual administrator password).*

---

## 5. Post-Join Verification

After VM 107 reboots, verify the domain connection using either method below:

### A. From Proxmox Host CLI:
```bash
# Check domain membership
qm guest exec 107 powershell.exe -- -Command "Get-CimInstance Win32_ComputerSystem | Select-Object Name, Domain, PartOfDomain"

# Test the Kerberos / Netlogon secure channel
qm guest exec 107 powershell.exe -- -Command "Test-ComputerSecureChannel -Verbose"
```

**Expected Results**:
* `Domain`: `dnd.local`
* `PartOfDomain`: `True`
* `Test-ComputerSecureChannel`: `True`

### B. On the Domain Controller (VM 138):
Verify that the computer account has registered in Active Directory:
```bash
qm guest exec 138 powershell.exe -- -Command "Get-ADComputer -Identity BT6-WS1 | Select-Object Name, DNSHostName, Enabled"
```

---

## 6. Checklist for Remaining Workstations (VMs 166, 182, 183)

To avoid this same error on the other workstations, apply the DNS fix before attempting to join:

```bash
# Set Primary DNS to DC (10.2.229.78) and secondary to pfSense (10.6.0.1)
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses ("10.2.229.78", "10.6.0.1")

# Verify DC discovery
nltest /dsgetdc:dnd.local

# Join domain
Add-Computer -DomainName "dnd.local" -Credential (Get-Credential) -Restart -Force
```
