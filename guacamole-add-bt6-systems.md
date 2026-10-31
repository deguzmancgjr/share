# Step-by-Step Guide: Adding BT6 Systems to Guacamole Node 2 (VM 108)

This guide provides detailed, verified procedures for adding the **Domain Controller (VM 138)**, **File Server (VM 158)**, and **Workstations (VMs 107, 166, 182, 183)** to **Apache Guacamole Node 2 (VM 108)**.

---

## 1. Environment & Systems Matrix

| System Name | VM ID | Hostname | IP Address | Subnet / Path | Protocol | Domain | Suggested Login |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **BT6 Domain Controller** | **138** | `WIN-NKNHGGC1IJE` | `10.2.229.78` | Direct via `ens19` (vmbr0) | **RDP** (3389) | `dnd.local` | `dnd\Administrator` |
| **BT6 File Server** | **158** | `BT6-DISGDNDCYCOM-FileSvr` | `10.6.0.3` | via pfSense `10.100.0.60` | **RDP** (3389) | `dnd.local` | `dnd\fileadmin` (or `Administrator`) |
| **BT6 Workstation 1** | **107** | `BT6-WS1` | `10.6.0.4` | via pfSense `10.100.0.60` | **RDP** (3389) | `dnd.local` | `dnd\BT6-User1` |
| **BT6 Workstation 2** | **166** | `BT6-WS2` | `10.6.0.5` | via pfSense `10.100.0.60` | **RDP** (3389) | `dnd.local` | `dnd\BT6-User2` |
| **BT6 Workstation 3** | **182** | `BT6-WS3` | `10.6.0.6` | via pfSense `10.100.0.60` | **RDP** (3389) | `dnd.local` | `dnd\BT6-User3` |
| **BT6 Workstation 4** | **183** | `BT6-WS4` | `10.6.0.7` | via pfSense `10.100.0.60` | **RDP** (3389) | `dnd.local` | `dnd\BT6-User4` |

* **Guacamole Node 2 Web Interface**: `https://10.2.229.50/guacamole/`
* **Default Admin Account**: `guacadmin`
* **Lab User Accounts**: `guacuser`, `redteam`

---

## 2. Mandatory Prerequisites & Network Routing

Before Guacamole can establish RDP sessions, two critical prerequisites must be fulfilled:

### Prerequisite 1: Enable RDP on Domain Controller (VM 138)
By default, Windows Server has Remote Desktop disabled (`fDenyTSConnections = 1`). Run this command on the Proxmox host terminal to enable RDP and open the Windows Firewall on VM 138:

```bash
qm guest exec 138 powershell.exe -- -Command '
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
Restart-Service TermService -Force
'
```

### Prerequisite 2: Persist Route for `10.6.0.0/24` on Guacamole (VM 108)
Guacamole Node 2 communicates with the `10.6.0.0/24` workstation subnet through the BT6 pfSense router WAN IP (`10.100.0.60`). 

To make this route permanent across reboots on VM 108, execute the following from the Proxmox host:

```bash
qm guest exec 108 -- bash -c '
# Add immediate active route
ip route replace 10.6.0.0/24 via 10.100.0.60 dev ens18

# Update netplan configuration to persist across reboots
if ! grep -q "10.6.0.0/24" /etc/netplan/50-cloud-init.yaml; then
  sed -i "/addresses:/i \      routes:\n        - to: 10.6.0.0/24\n          via: 10.100.0.60" /etc/netplan/50-cloud-init.yaml
  netplan apply
fi
'
```

---

## 3. Method 1: Fast Automated Setup via Proxmox Host CLI (Recommended)

You can automatically create all 6 connections organized in a neat **"BT6-DND"** connection folder in Guacamole's database with a single script execution.

Run this command directly from the Proxmox host terminal:

```bash
qm guest exec 108 -- bash -c 'docker exec -i guacamole_mysql mysql -u guacuser -pguacpassword guacamole_db << "EOF"
-- 1. Create Connection Group for BT6
INSERT INTO guacamole_connection_group (connection_group_name, type) 
VALUES ("BT6-DND", "ORGANIZATIONAL")
ON DUPLICATE KEY UPDATE connection_group_id=LAST_INSERT_ID(connection_group_id);
SET @group_id = LAST_INSERT_ID();

-- 2. Procedure to insert connection with parameters and permissions
DROP PROCEDURE IF EXISTS AddGuacRdp;
DELIMITER $$
CREATE PROCEDURE AddGuacRdp(
    IN p_name VARCHAR(128),
    IN p_host VARCHAR(128),
    IN p_user VARCHAR(128),
    IN p_pass VARCHAR(128),
    IN p_domain VARCHAR(128),
    IN p_parent INT
)
BEGIN
    DECLARE v_conn_id INT;
    
    -- Insert or update connection
    SELECT connection_id INTO v_conn_id FROM guacamole_connection WHERE connection_name = p_name AND parent_id = p_parent LIMIT 1;
    
    IF v_conn_id IS NULL THEN
        INSERT INTO guacamole_connection (connection_name, protocol, parent_id) VALUES (p_name, "rdp", p_parent);
        SET v_conn_id = LAST_INSERT_ID();
    END IF;
    
    -- Clear and insert parameters
    DELETE FROM guacamole_connection_parameter WHERE connection_id = v_conn_id;
    INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value) VALUES
        (v_conn_id, "hostname", p_host),
        (v_conn_id, "port", "3389"),
        (v_conn_id, "username", p_user),
        (v_conn_id, "password", p_pass),
        (v_conn_id, "domain", p_domain),
        (v_conn_id, "security", "any"),
        (v_conn_id, "ignore-cert", "true"),
        (v_conn_id, "cert-tofu", "true"),
        (v_conn_id, "enable-wallpaper", "true"),
        (v_conn_id, "enable-theming", "true"),
        (v_conn_id, "enable-font-smoothing", "true"),
        (v_conn_id, "resize-method", "display-update");
        
    -- Grant read & admin permissions to guacadmin and redteam
    INSERT IGNORE INTO guacamole_connection_permission (entity_id, connection_id, permission)
    SELECT entity_id, v_conn_id, "READ" FROM guacamole_entity WHERE name IN ("guacadmin", "redteam", "guacuser");
    INSERT IGNORE INTO guacamole_connection_permission (entity_id, connection_id, permission)
    SELECT entity_id, v_conn_id, "ADMINISTER" FROM guacamole_entity WHERE name = "guacadmin";
END$$
DELIMITER ;

-- 3. Add BT6 Systems
CALL AddGuacRdp("BT6-DND-DC",   "10.2.229.78", "Administrator", "Ajex@2026", "dnd.local", @group_id);
CALL AddGuacRdp("BT6-FileSvr",  "10.6.0.3",    "fileadmin",     "Ajex@2026", "dnd.local", @group_id);
CALL AddGuacRdp("BT6-WS1",      "10.6.0.4",    "BT6-User1",     "Ajex@2026", "dnd.local", @group_id);
CALL AddGuacRdp("BT6-WS2",      "10.6.0.5",    "BT6-User2",     "Ajex@2026", "dnd.local", @group_id);
CALL AddGuacRdp("BT6-WS3",      "10.6.0.6",    "BT6-User3",     "Ajex@2026", "dnd.local", @group_id);
CALL AddGuacRdp("BT6-WS4",      "10.6.0.7",    "BT6-User4",     "Ajex@2026", "dnd.local", @group_id);

-- Clean up
DROP PROCEDURE IF EXISTS AddGuacRdp;
EOF
'
```

*Note: If your lab environment uses a password other than `Ajex@2026`, simply replace `"Ajex@2026"` in the script above or leave it empty `""` to prompt upon connection.*

---

## 4. Method 2: Step-by-Step Manual Web GUI Procedure

If you prefer configuring via the Guacamole Web Interface:

### Step 4.1: Log into Guacamole
1. Open your browser and go to:
   ```
   https://10.2.229.50/guacamole/
   ```
2. Log in as **`guacadmin`**.
3. In the upper-right corner, click on your username (`guacadmin`) and select **Settings**.

---

### Step 4.2: (Optional) Create Connection Group
1. Click the **Connections** tab.
2. Click **New Group**.
3. Set **Group Name**: `BT6-DND`
4. Set **Type**: `Organizational`
5. Click **Save**.

---

### Step 4.3: Add Connection for Each System

Click **New Connection** on the Connections tab and fill in the details for each target:

#### 1. BT6 Domain Controller (VM 138)
* **Name**: `BT6-DND-DC`
* **Location**: `BT6-DND` (or `ROOT`)
* **Protocol**: `RDP`
* **Parameters**:
  * **Network**:
    * **Hostname**: `10.2.229.78`
    * **Port**: `3389`
  * **Authentication**:
    * **Username**: `Administrator`
    * **Password**: `<DOMAIN_ADMIN_PASSWORD>` (or leave empty to enter at login)
    * **Domain**: `dnd.local`
    * **Security mode**: `Any`
    * **Ignore server certificate**: `Checked` (True)
  * **Display**:
    * **Color depth**: `24-bit color (True color)`
    * **Resize method**: `Display Update`
* Click **Save**.

---

#### 2. BT6 File Server (VM 158)
* **Name**: `BT6-FileSvr`
* **Protocol**: `RDP`
* **Parameters**:
  * **Hostname**: `10.6.0.3`
  * **Port**: `3389`
  * **Username**: `fileadmin` (or `Administrator`)
  * **Password**: `<FILEADMIN_PASSWORD>`
  * **Domain**: `dnd.local`
  * **Security mode**: `Any`
  * **Ignore server certificate**: `Checked` (True)
* Click **Save**.

---

#### 3. BT6 Workstations (VMs 107, 166, 182, 183)
Repeat for each workstation:

| Connection Name | Hostname | Username | Domain | Security Mode | Ignore Cert |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `BT6-WS1` | `10.6.0.4` | `BT6-User1` | `dnd.local` | `Any` | Checked |
| `BT6-WS2` | `10.6.0.5` | `BT6-User2` | `dnd.local` | `Any` | Checked |
| `BT6-WS3` | `10.6.0.6` | `BT6-User3` | `dnd.local` | `Any` | Checked |
| `BT6-WS4` | `10.6.0.7` | `BT6-User4` | `dnd.local` | `Any` | Checked |

---

### Step 4.4: Grant User Permissions
If other users (such as `redteam` or student users) need access:
1. In **Settings**, click the **Users** tab.
2. Select the target user (e.g. `redteam`).
3. Scroll to the **Permissions** / **Connections** section.
4. Check the box next to **BT6-DND** (or check individual workstations).
5. Click **Save**.

---

## 5. Verification & Testing

### 1. Test from Guacamole Host (CLI connectivity)
You can verify direct connectivity from VM 108 to each machine:
```bash
# Verify Domain Controller (10.2.229.78)
qm guest exec 108 -- nc -zv -w 2 10.2.229.78 3389

# Verify File Server (10.6.0.3)
qm guest exec 108 -- nc -zv -w 2 10.6.0.3 3389

# Verify Workstation 1 (10.6.0.4)
qm guest exec 108 -- nc -zv -w 2 10.6.0.4 3389
```
**Expected Output**: `Connection to ... 3389 port [tcp/ms-wbt-server] succeeded!`

### 2. Test in Guacamole Web Interface
1. Return to the Guacamole home screen (`https://10.2.229.50/guacamole/#/`).
2. Expand the **BT6-DND** folder.
3. Click on **BT6-DND-DC** or any workstation (`BT6-WS1`).
4. The Windows desktop session will launch smoothly inside the browser.

---

## 6. Troubleshooting Common Issues

| Issue / Symptom | Root Cause | Solution |
| :--- | :--- | :--- |
| **Connection timed out** on DC (`10.2.229.78`) | Remote Desktop is disabled on Windows Server by default. | Run the prerequisite command in Section 2 to set `fDenyTSConnections = 0` on VM 138. |
| **Connection timed out** on `10.6.0.x` systems | Missing route to `10.6.0.0/24` on VM 108. | Run `ip route add 10.6.0.0/24 via 10.100.0.60 dev ens18` on VM 108. |
| **The remote desktop server encountered an error** / Certificate error | Self-signed RDP SSL certificates rejected by `guacd`. | Ensure **Ignore server certificate** (`ignore-cert: true`) is enabled on the connection. |
| **Account locked / Logon failure** | Wrong domain or password entered in connection parameters. | Verify Domain is set to `dnd.local` (or `DND`) and username is correct. |
| **Connection refused (Port 3389)** | Target VM is powered off or TermService is not running. | Verify VM is running in Proxmox (`qm status <vmid>`). |
