# Step-by-Step Guide: Access and Add BT7 WESCOM VMs to Guacamole Node 2 (VM 108)

This guide covers how to access the BT7 lab environment on Proxmox node `node2`,
how to fix the network path from Guacamole VM `108`, and how to organize the
BT7 systems in Guacamole as the **BT7-WESCOM** connection group.

The BT7 Guacamole connections already exist in the database. They are not usable
until the route and pfSense WAN rule are corrected.

> **Status 2026-11-03:** Access is fixed and verified. The netplan route and
> pfSense WAN rules described below were already in place. The remaining faults
> were a `vmbr1` VLAN mismatch and a missing route on the BT7 DC. See
> Section 3.1 for the applied fixes.

---

## 1. Environment Matrix

| System | VM ID | Hostname | Management IP | Lab IP | Role |
| :--- | :--- | :--- | :--- | :--- | :--- |
| Proxmox node | host | `node2` | `10.2.229.10` | - | Proxmox VE host |
| Guacamole | **108** | `guacamole-node2` | `10.2.229.50` | `10.100.0.50` | Guacamole web + guacd |
| BT7 pfSense | **124** | `BT7-WESCOM-PFSENSE` | - | WAN `10.100.0.70`, LAN `10.7.0.1` | Router / firewall |
| BT7 DC | **195** | `WIN-NKNHGGC1IJE` | `10.2.229.80` | `10.7.0.2` | Domain controller |
| BT7 File Server | **159** | `WIN-FILESVR` | - | `10.7.0.3` | File server |
| BT7 WS1 | **147** | `BT7-WESCOM-WS1` | - | `10.7.0.4` | Workstation |
| BT7 WS2 | **148** | `BT7-WESCOM-WS2` | - | `10.7.0.5` | Workstation |
| BT7 WS3 | **184** | `BT7-WESCOM-WS3` | - | `10.7.0.6` | Workstation |
| BT7 WS4 | **185** | `BT7-WESCOM-WS4` | - | `10.7.0.7` | Workstation |

### Active Directory values

| Item | Value |
| :--- | :--- |
| Domain FQDN | `wescom.local` |
| NetBIOS name | `WESCOM` |
| Domain controller | `WIN-NKNHGGC1IJE.wescom.local` |
| Domain admin | `WESCOM\Administrator` |

### Guacamole targets

| Connection name | Target IP | RDP user | Domain |
| :--- | :--- | :--- | :--- |
| `BT7-DC` | `10.2.229.80` (recommended) or `10.7.0.2` | `Administrator` | `wescom.local` |
| `BT7-FileSvr` | `10.7.0.3` | `fileadmin` | `wescom.local` |
| `BT7-WS1` | `10.7.0.4` | `BT7-User1` | `wescom.local` |
| `BT7-WS2` | `10.7.0.5` | `BT7-User2` | `wescom.local` |
| `BT7-WS3` | `10.7.0.6` | `BT7-User3` | `wescom.local` |
| `BT7-WS4` | `10.7.0.7` | `BT7-User4` | `wescom.local` |

> **Passwords:** This document intentionally uses placeholders:
> `<WESCOM_USER_PASSWORD>` and `<WESCOM_ADMIN_PASSWORD>`.
> Existing Guacamole connections already have stored passwords. Do not commit
> real lab passwords to this repository.

---

## 2. How to Access the Environment

### 2.1 Access the Proxmox host

Use SSH with your Proxmox administrator account:

```bash
ssh root@10.2.229.10
```

Or open the Proxmox web UI:

```text
https://10.2.229.10:8006
```

Useful host commands:

```bash
qm list
qm status 108
qm status 124
qm config 108
qm guest exec 108 --timeout 20 -- ip -br a
```

### 2.2 Access Guacamole Node 2

Direct URL, from an allowed network:

```text
https://10.2.229.50/guacamole/
```

If your workstation is not in the Caddy allowlist, use the node1 proxy:

```text
https://10.2.229.60:8443/guacamole/
```

The Caddy allowlist on VM 108 permits `10.2.228.0/24` and `10.2.229.0/24`.
A `403 Forbidden` from `10.2.229.50` means your source IP is not allowed; use
the proxy URL or update the Caddy allowlist.

### 2.3 Access a VM console

For any Windows VM, select the VM in the Proxmox UI and open **Console**.
This is required for VM 159 because its QEMU guest agent is currently not
running, so `qm guest exec` commands will fail.

---

## 3. Current Root Causes

Three problems prevent BT7 Guacamole connections from working:

1. **Missing route on VM 108.**
   VM 108 currently sends traffic for `10.7.0.0/24` to `10.100.0.1`, not to the
   BT7 pfSense WAN `10.100.0.70`.

   ```text
   10.7.0.4 via 10.100.0.1 dev ens18 src 10.100.0.50
   ```

2. **pfSense WAN blocks Guacamole.**
   The BT7 pfSense WAN currently permits SSH/HTTPS/ICMP only from
   `10.100.0.164`. It does not permit RDP from Guacamole VM 108
   (`10.100.0.50`) to the `10.7.0.0/24` LAN.

3. **VM 108 netplan is invalid.**
   `/etc/netplan/50-cloud-init.yaml` has malformed YAML and duplicate keys.
   `netplan get` currently fails. Do not run `netplan apply` until the file is
   corrected using Section 5.

Additional findings:

- RDP is enabled and TCP 3389 is open on VMs `195`, `147`, `148`, `184`, `185`.
- VM 159 (`10.7.0.3`) accepts RDP from pfSense, but its guest agent is not running.
- The Guacamole connections `BT7-DC`, `BT7-FileSvr`, and `BT7-WS1-4` already
  exist as connection IDs `22`-`27`, but they are at the root and only
  `guacadmin` has permissions.
- VM 185 currently has `WESCOM\BT7-User3` in its local Remote Desktop Users
  group, but the `BT7-WS4` Guacamole connection uses `BT7-User4`. Correct this
  in Section 4.3.

---

## 3.1 Actual fixes applied on 2026-11-03

The three items in Section 3 were already resolved: the `10.7.0.0/24` route is
present in VM 108, the netplan parses cleanly, and the pfSense WAN RDP/ICMP
rules exist. Two different faults were blocking access.

### 3.1.1 `vmbr1` VLAN mismatch (root cause)

`vmbr1` is VLAN-aware (`bridge-vlan-aware yes`, `bridge-vids 2-4094`). A prior
change moved VM 108 and **both** pfSense NICs to VLAN 2, while every BT7 LAN VM
remained on VLAN 1:

```text
tap108i0    2 PVID   (should be 1)
fwpr124p0   2 PVID   (pfSense WAN, should be 1)
fwpr124p1   2 PVID   (pfSense LAN, should be 1)
fwpr147p0   1 PVID   (BT7 WS1)
fwpr148p0   1 PVID   (BT7 WS2)
fwpr159p0   1 PVID   (BT7 FileSvr)
fwpr184p0   1 PVID   (BT7 WS3)
fwpr185p0   1 PVID   (BT7 WS4)
fwpr195p1   1 PVID   (BT7 DC LAN)
```

Because pfSense LAN was on VLAN 2, it could not reach the VLAN 1 BT7 hosts.
Because VM 108 was on VLAN 2, it also lost the shared `10.100.0.0/24` WAN
(`10.100.0.1` upstream and `10.100.0.60` BT6 pfSense).

Revert those three ports to VLAN 1. This also matches the default PVID that is
applied when the VM NICs are recreated, so the change survives VM restarts:

```bash
for p in tap108i0 fwpr124p0 fwpr124p1; do
  bridge vlan add dev "$p" vid 1 pvid untagged
  bridge vlan del dev "$p" vid 2
done
```

Verify:

```bash
for p in tap108i0 fwpr124p0 fwpr124p1; do
  bridge vlan show dev "$p" | sed -n '2p'
done
```

### 3.1.2 BT7 DC has no gateway on the lab NIC (root cause)

VM 195 (`10.7.0.2`) had no default gateway on `Ethernet 2`. Its only default
route used the management NIC (`10.2.229.1`), so replies to Guacamole
(`10.100.0.50`) left through the wrong interface. pfSense could reach the DC
because `10.7.0.1` is on-link, but Guacamole could not.

Add a persistent, specific route for the Guacamole WAN subnet:

```powershell
New-NetRoute -DestinationPrefix "10.100.0.0/24" -NextHop "10.7.0.1" `
  -InterfaceAlias "Ethernet 2" -RouteMetric 256 -PolicyStore PersistentStore
```

Verify:

```powershell
Get-NetRoute -PolicyStore PersistentStore -DestinationPrefix "10.100.0.0/24"
```

### 3.1.3 Guacamole organization

The six connections already existed at the root as IDs `22`-`27` with correct
hosts, users, domains, and stored passwords. The `BT7-WESCOM` **connection
group** did not exist (only a same-named user group did). The following was
applied:

- Created organizational connection group `BT7-WESCOM` (ID `1`).
- Moved `BT7-DC`, `BT7-FileSvr`, and `BT7-WS1`-`BT7-WS4` into it.
- Added `cert-tofu`, `enable-wallpaper`, `enable-theming`, and
  `enable-font-smoothing` parameters without changing stored passwords.
- Granted `READ` on the group and all six connections to `redteam`,
  `guacuser`, `BT7-User`, and the `BT7-WESCOM` user group; `guacadmin` keeps
  `ADMINISTER`.

### 3.1.4 Verified result

```text
guacd -> 10.2.229.80:3389 OPEN   (BT7-DC via management)
guacd -> 10.7.0.2:3389 OPEN
guacd -> 10.7.0.3:3389 OPEN
guacd -> 10.7.0.4:3389 OPEN
guacd -> 10.7.0.5:3389 OPEN
guacd -> 10.7.0.6:3389 OPEN
guacd -> 10.7.0.7:3389 OPEN
```

`10.100.0.1` and `10.100.0.60` are reachable from VM 108 again, and
`10.6.0.4:3389` (BT6) still works.

---

## 4. Preflight Checks and Fixes

### 4.1 Confirm all BT7 VMs are running

From the Proxmox host:

```bash
qm status 108
qm status 124
qm status 159
qm status 195
qm status 147
qm status 148
qm status 184
qm status 185
```

Expected status for each:

```text
status: running
```

Start any stopped VM with:

```bash
qm start <vmid>
```

### 4.2 Confirm RDP is enabled

Run from the Proxmox host for VMs with a working guest agent:

```bash
for vmid in 195 147 148 184 185; do
  echo "=== VM $vmid ==="
  qm guest exec "$vmid" --timeout 20 powershell.exe -- -NoProfile -Command '
    (Get-ItemProperty "HKLM:\System\CurrentControlSet\Control\Terminal Server").fDenyTSConnections
    (Get-Service TermService).Status
    Get-NetFirewallRule -DisplayGroup "Remote Desktop" |
      Select-Object DisplayName,Enabled,Direction,Action |
      Format-Table -AutoSize
  '
done
```

Expected:

```text
0
Running
```

RDP firewall rules must be `Enabled=True`, `Direction=Inbound`, `Action=Allow`.

If RDP is disabled on a VM, run:

```bash
qm guest exec <vmid> --timeout 30 powershell.exe -- -NoProfile -Command '
  Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0
  Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
  Restart-Service TermService -Force
'
```

### 4.3 Correct the WS4 Remote Desktop group

VM 185 currently allows `WESCOM\BT7-User3`, not `WESCOM\BT7-User4`.
Add the correct user:

```bash
qm guest exec 185 --timeout 20 powershell.exe -- -NoProfile -Command '
  Add-LocalGroupMember -Group "Remote Desktop Users" -Member "WESCOM\BT7-User4" -ErrorAction SilentlyContinue
'
```

Verify:

```bash
qm guest exec 185 --timeout 20 powershell.exe -- -NoProfile -Command '
  Get-LocalGroupMember -Group "Remote Desktop Users" |
    Select-Object Name,ObjectClass |
    Format-Table -AutoSize
'
```

### 4.4 Confirm RDP from pfSense LAN

From pfSense VM 124:

```bash
qm guest exec 124 --timeout 30 -- /bin/sh -c '
  for ip in 10.7.0.2 10.7.0.3 10.7.0.4 10.7.0.5 10.7.0.6 10.7.0.7; do
    echo -n "$ip:3389 "
    /usr/bin/nc -z -w 2 "$ip" 3389 >/dev/null 2>&1 && echo OPEN || echo CLOSED
  done
'
```

Expected for all six:

```text
10.7.0.x:3389 OPEN
```

### 4.5 Confirm pfSense private-network blocking is disabled

```bash
qm guest exec 124 --timeout 20 -- /bin/sh -c 'grep -c blockpriv /cf/conf/config.xml'
```

Expected:

```text
0
```

If it returns `1`, disable **Block private networks and loopback addresses**
under **Interfaces > WAN** in the pfSense GUI, then apply changes.

---

## 5. Fix the VM 108 Route and netplan

### 5.1 Back up the current netplan

```bash
qm guest exec 108 --timeout 30 -- bash -c '
  TS=$(date +%Y%m%d-%H%M%S)
  cp -a /etc/netplan/50-cloud-init.yaml /root/50-cloud-init.yaml.bak-$TS
  ls -l /root/50-cloud-init.yaml.bak-$TS
'
```

### 5.2 Replace the malformed netplan file

The current file fails YAML parsing. Replace it with the following corrected
configuration. It preserves the existing `10.6.0.0/24` BT6 route and adds the
BT7 `10.7.0.0/24` route via pfSense WAN `10.100.0.70`.

```bash
qm guest exec 108 --timeout 60 -- bash -c 'cat > /etc/netplan/50-cloud-init.yaml << "EOF"
network:
  version: 2
  renderer: networkd
  ethernets:
    lab:
      match:
        macaddress: "bc:24:11:a5:3e:82"
      dhcp4: false
      addresses:
        - 10.100.0.50/24
      routes:
        - to: default
          via: 10.100.0.1
        - to: 10.6.0.0/24
          via: 10.100.0.60
        - to: 10.7.0.0/24
          via: 10.100.0.70
      optional: true

    mgmt:
      match:
        macaddress: "bc:24:11:63:39:26"
      dhcp4: false
      dhcp6: false
      accept-ra: false
      addresses:
        - 10.2.229.50/24
      routes:
        - to: default
          via: 10.2.229.1
          metric: 100
        - to: 10.2.228.0/24
          via: 10.2.229.1
        - to: 10.2.196.0/24
          via: 10.2.229.1
      nameservers:
        addresses: [10.2.196.11, 10.2.196.12]
        search: [ad.phl-imcite.net]
EOF
chmod 600 /etc/netplan/50-cloud-init.yaml
'
```

### 5.3 Validate and apply the netplan

Do not apply until `netplan get` succeeds.

```bash
qm guest exec 108 --timeout 30 -- bash -c 'netplan get'
```

Expected: it prints the parsed YAML with no error.

Apply the configuration:

```bash
qm guest exec 108 --timeout 60 -- bash -c 'netplan generate && netplan apply'
```

> `netplan apply` briefly reconfigures both VM 108 interfaces. If you are
> connected over SSH to `10.2.229.50`, the session may pause. The QEMU guest
> agent path remains available from the Proxmox host.

### 5.4 Add an immediate route if you do not want to apply netplan yet

For a quick test before persisting, run:

```bash
qm guest exec 108 --timeout 20 -- bash -c 'ip route replace 10.7.0.0/24 via 10.100.0.70 dev ens18'
```

This route is temporary and will be lost on reboot. Section 5.2/5.3 makes it
persistent.

### 5.5 Verify routing

```bash
qm guest exec 108 --timeout 20 -- bash -c '
  ip route get 10.7.0.2
  ip route get 10.7.0.3
  ip route get 10.7.0.4
'
```

Expected:

```text
10.7.0.x via 10.100.0.70 dev ens18 src 10.100.0.50
```

If the route still points at `10.100.0.1`, the route was not applied.

---

## 6. Fix pfSense WAN Access for Guacamole

Guacamole's `guacd` container uses Docker masquerading, so its connections
appear to pfSense as coming from VM 108 lab IP `10.100.0.50`, not from the
`172.18.0.0/16` Docker subnet.

### 6.1 Recommended: add rules with easyrule

From the Proxmox host:

```bash
# Allow RDP from Guacamole VM 108 to the BT7 LAN
qm guest exec 124 --timeout 30 -- /usr/local/bin/easyrule pass wan tcp 10.100.0.50 10.7.0.0/24 3389

# Optional: allow ICMP for testing
qm guest exec 124 --timeout 30 -- /usr/local/bin/easyrule pass wan icmp 10.100.0.50 10.7.0.0/24
```

`easyrule` applies the rules immediately. No pfSense restart is required.

Verify the rules exist:

```bash
qm guest exec 124 --timeout 20 -- /bin/sh -c '
  pfctl -sr 2>/dev/null | grep "10.100.0.50"
'
```

Expected to include a `pass in quick on em0 ... from 10.100.0.50 ... port = 3389`
rule.

### 6.2 Alternative: add rules with the pfSense GUI

1. Open `https://10.100.0.70` from VM 164 or another permitted admin host.
2. Log in to pfSense.
3. Go to **Firewall > Rules > WAN**.
4. Click **Add** (top, arrow up).
5. Create the RDP rule:
   - **Action**: `Pass`
   - **Interface**: `WAN`
   - **Address Family**: `IPv4`
   - **Protocol**: `TCP`
   - **Source**: `Single host or alias` = `10.100.0.50`
   - **Destination**: `Network` = `10.7.0.0/24`
   - **Destination Port Range**: `3389` to `3389`
   - **Description**: `Allow BT7 RDP from Guacamole node2`
6. Click **Save**.
7. Optionally add an ICMP rule with the same source/destination for testing.
8. Click **Apply Changes**.

Do not use `any` as the source. Restrict the rule to `10.100.0.50/32`.

---

## 7. Configure the BT7 Guacamole Connections

The BT7 connections already exist. This section creates the `BT7-WESCOM`
organizational group, moves the existing connections into it, updates the
connection parameters, and grants access to lab users.

### 7.1 Method 1: Automated SQL setup (recommended)

Run this from the Proxmox host:

```bash
qm guest exec 108 --timeout 90 -- bash -c 'docker exec -i guacamole_mysql mysql -u guacuser -pguacpassword guacamole_db << "EOF"
-- 1. Create the BT7 connection group if it does not exist
INSERT INTO guacamole_connection_group (connection_group_name, type)
SELECT "BT7-WESCOM", "ORGANIZATIONAL" FROM DUAL
WHERE NOT EXISTS (
  SELECT 1 FROM guacamole_connection_group
  WHERE connection_group_name = "BT7-WESCOM" AND parent_id IS NULL
);

SET @gid := (
  SELECT connection_group_id FROM guacamole_connection_group
  WHERE connection_group_name = "BT7-WESCOM" AND parent_id IS NULL
  ORDER BY connection_group_id LIMIT 1
);

-- 2. Procedure to create or update an RDP connection
DROP PROCEDURE IF EXISTS UpsertBt7Rdp;
DELIMITER $$
CREATE PROCEDURE UpsertBt7Rdp(
  IN p_name VARCHAR(128),
  IN p_host VARCHAR(128),
  IN p_user VARCHAR(128),
  IN p_domain VARCHAR(128),
  IN p_pass VARCHAR(128),
  IN p_parent INT
)
BEGIN
  DECLARE v_id INT;

  SELECT connection_id INTO v_id
  FROM guacamole_connection
  WHERE connection_name = p_name
  ORDER BY connection_id LIMIT 1;

  IF v_id IS NULL THEN
    INSERT INTO guacamole_connection (connection_name, protocol, parent_id)
    VALUES (p_name, "rdp", p_parent);
    SET v_id = LAST_INSERT_ID();
  ELSE
    UPDATE guacamole_connection
    SET protocol = "rdp", parent_id = p_parent
    WHERE connection_id = v_id;
  END IF;

  INSERT INTO guacamole_connection_parameter
    (connection_id, parameter_name, parameter_value)
  VALUES
    (v_id, "hostname", p_host),
    (v_id, "port", "3389"),
    (v_id, "username", p_user),
    (v_id, "domain", p_domain),
    (v_id, "security", "any"),
    (v_id, "ignore-cert", "true"),
    (v_id, "cert-tofu", "true"),
    (v_id, "enable-wallpaper", "true"),
    (v_id, "enable-theming", "true"),
    (v_id, "enable-font-smoothing", "true"),
    (v_id, "resize-method", "display-update"),
    (v_id, "color-depth", "24")
  ON DUPLICATE KEY UPDATE parameter_value = VALUES(parameter_value);

  -- Preserve existing passwords when p_pass is NULL or empty
  IF p_pass IS NOT NULL AND p_pass <> "" THEN
    INSERT INTO guacamole_connection_parameter
      (connection_id, parameter_name, parameter_value)
    VALUES (v_id, "password", p_pass)
    ON DUPLICATE KEY UPDATE parameter_value = VALUES(parameter_value);
  END IF;
END$$
DELIMITER ;

-- 3. Create or update BT7 systems
-- Use NULL to keep the existing stored password.
CALL UpsertBt7Rdp("BT7-DC",      "10.2.229.80", "Administrator", "wescom.local", NULL, @gid);
CALL UpsertBt7Rdp("BT7-FileSvr", "10.7.0.3",    "fileadmin",     "wescom.local", NULL, @gid);
CALL UpsertBt7Rdp("BT7-WS1",     "10.7.0.4",    "BT7-User1",     "wescom.local", NULL, @gid);
CALL UpsertBt7Rdp("BT7-WS2",     "10.7.0.5",    "BT7-User2",     "wescom.local", NULL, @gid);
CALL UpsertBt7Rdp("BT7-WS3",     "10.7.0.6",    "BT7-User3",     "wescom.local", NULL, @gid);
CALL UpsertBt7Rdp("BT7-WS4",     "10.7.0.7",    "BT7-User4",     "wescom.local", NULL, @gid);

-- 4. Grant access to the group and all BT7 connections
INSERT IGNORE INTO guacamole_connection_group_permission
  (entity_id, connection_group_id, permission)
SELECT entity_id, @gid, "READ"
FROM guacamole_entity
WHERE name IN ("redteam", "guacuser");

INSERT IGNORE INTO guacamole_connection_permission
  (entity_id, connection_id, permission)
SELECT e.entity_id, c.connection_id, "READ"
FROM guacamole_entity e
JOIN guacamole_connection c ON c.parent_id = @gid
WHERE e.name IN ("redteam", "guacuser");

INSERT IGNORE INTO guacamole_connection_permission
  (entity_id, connection_id, permission)
SELECT e.entity_id, c.connection_id, "ADMINISTER"
FROM guacamole_entity e
JOIN guacamole_connection c ON c.parent_id = @gid
WHERE e.name = "guacadmin";

DROP PROCEDURE IF EXISTS UpsertBt7Rdp;
EOF
'
```

If you need to store a password for a newly created connection, replace `NULL`
in the corresponding `CALL` with `<WESCOM_USER_PASSWORD>` or
`<WESCOM_ADMIN_PASSWORD>`. Do not save the real password in this document.

### 7.2 Verify the database state

```bash
qm guest exec 108 --timeout 30 -- bash -c 'docker exec -i guacamole_mysql mysql -u guacuser -pguacpassword -N -e "
SELECT c.connection_id, c.connection_name, c.parent_id,
       MAX(CASE WHEN p.parameter_name = \"hostname\" THEN p.parameter_value END) AS host,
       MAX(CASE WHEN p.parameter_name = \"username\" THEN p.parameter_value END) AS user,
       MAX(CASE WHEN p.parameter_name = \"domain\" THEN p.parameter_value END) AS domain,
       MAX(CASE WHEN p.parameter_name = \"password\" THEN \"SET\" END) AS password_set
FROM guacamole_db.guacamole_connection c
JOIN guacamole_db.guacamole_connection_group g
  ON g.connection_group_id = c.parent_id
LEFT JOIN guacamole_db.guacamole_connection_parameter p
  ON p.connection_id = c.connection_id
WHERE g.connection_group_name = \"BT7-WESCOM\"
GROUP BY c.connection_id, c.connection_name, c.parent_id
ORDER BY c.connection_id;
"' 2>&1 | tail -20
```

Expected: six rows under the same `parent_id`, with the correct host, user, and
domain values. `password_set` should show `SET` for connections that already had
stored passwords.

### 7.3 Method 2: Manual Guacamole GUI setup

1. Open `https://10.2.229.50/guacamole/`.
2. Log in as `guacadmin`.
3. Click your username in the top-right and select **Settings**.
4. Open the **Connections** tab.
5. Click **New Group**:
   - **Group Name**: `BT7-WESCOM`
   - **Type**: `Organizational`
   - Click **Save**.
6. Edit each existing BT7 connection and set **Location** to `BT7-WESCOM`.
7. For each connection, verify:
   - **Protocol**: `RDP`
   - **Hostname**: target IP from the table in Section 1
   - **Port**: `3389`
   - **Username**: correct BT7 user
   - **Domain**: `wescom.local`
   - **Security mode**: `Any`
   - **Ignore server certificate**: checked
   - **Color depth**: `24-bit`
   - **Resize method**: `Display Update`
8. Leave the password field unchanged for existing connections.
   For a new connection, enter the password or leave it blank to prompt at login.
9. Click **Save** after each connection.

---

## 8. Grant Permissions in the GUI

If you did not use the SQL method:

1. Go to **Settings > Users**.
2. Select `redteam`.
3. Under **Permissions**, enable `BT7-WESCOM` and all six BT7 connections.
4. Click **Save**.
5. Repeat for `guacuser`.

`guacadmin` already has administrator access.

---

## 9. Verification

### 9.1 Test from the VM 108 host

```bash
qm guest exec 108 --timeout 40 -- bash -c '
  for ip in 10.7.0.2 10.7.0.3 10.7.0.4 10.7.0.5 10.7.0.6 10.7.0.7; do
    echo -n "$ip:3389 "
    timeout 3 bash -c "echo > /dev/tcp/$ip/3389" 2>/dev/null && echo OPEN || echo CLOSED
  done
'
```

Expected:

```text
10.7.0.2:3389 OPEN
10.7.0.3:3389 OPEN
10.7.0.4:3389 OPEN
10.7.0.5:3389 OPEN
10.7.0.6:3389 OPEN
10.7.0.7:3389 OPEN
```

### 9.2 Test from the guacd container

This is the most important test because it matches how Guacamole connects:

```bash
qm guest exec 108 --timeout 40 -- bash -c '
  for ip in 10.7.0.2 10.7.0.3 10.7.0.4 10.7.0.5 10.7.0.6 10.7.0.7; do
    echo -n "guacd -> $ip:3389 "
    docker exec guacd nc -z -w 3 "$ip" 3389 >/dev/null 2>&1 && echo OPEN || echo CLOSED
  done
'
```

All six must report `OPEN`.

### 9.3 Test from the Guacamole web interface

1. Open `https://10.2.229.50/guacamole/`.
2. Expand **BT7-WESCOM**.
3. Open `BT7-DC`. It uses `10.2.229.80`, so it should work even before the
   pfSense WAN rule is applied.
4. Open `BT7-FileSvr` and `BT7-WS1` through `BT7-WS4`.
5. Log in with the matching BT7 domain user.

If the connection opens but Windows rejects the login, confirm:

```text
Domain: wescom.local
Username: BT7-User1 (or the correct user for that VM)
Password: the current lab password
```

### 9.4 Test with a non-admin Guacamole user

Log out of `guacadmin`, log in as `redteam` or `guacuser`, and confirm the
`BT7-WESCOM` group and its six connections are visible.

---

## 10. Troubleshooting

| Symptom | Root cause | Fix |
| :--- | :--- | :--- |
| `10.7.0.x:3389 CLOSED` from VM 108 | Route missing or pointing to `10.100.0.1` | Apply Section 5 and verify with `ip route get 10.7.0.4`. |
| Host can reach `10.7.0.x`, guacd cannot | pfSense WAN rule missing or wrong source | Confirm the WAN rule allows `10.100.0.50` to `10.7.0.0/24` port `3389`. |
| Connection times out in browser | pfSense WAN default-deny | Add the RDP pass rule in Section 6. |
| `403 Forbidden` at `https://10.2.229.50` | Source IP not in Caddy allowlist | Use `https://10.2.229.60:8443/guacamole/` or add your subnet to the Caddyfile. |
| Certificate error / RDP TLS failure | Self-signed RDP certificate | Ensure `ignore-cert` and `cert-tofu` are `true`. |
| `The logon attempt was unsuccessful` | Wrong domain, username, or password | Use domain `wescom.local`, the correct BT7 user, and the current lab password. |
| WS4 login fails for `BT7-User4` | VM 185 RDP group currently lists `BT7-User3` | Run the fix in Section 4.3. |
| File server guest agent errors | QEMU guest agent is not running on VM 159 | Use the Proxmox console, or install/start `qemu-guest-agent` in Windows. |
| `netplan get` fails | `50-cloud-init.yaml` is invalid YAML | Replace it using Section 5.2 before running `netplan apply`. |
| Connection works until VM 108 reboots | Route was added only at runtime | Persist the `10.7.0.0/24` route in netplan using Section 5.2/5.3. |
| Guacamole group missing for `redteam` | Only `guacadmin` has connection permissions | Run the permission SQL in Section 7.1 or use Section 8. |

### Useful diagnostics

From VM 108:

```bash
qm guest exec 108 --timeout 20 -- bash -c '
  ip route
  ip route get 10.7.0.4
  ping -c 2 10.7.0.1
  ss -tlnp | grep 8080
  docker ps
'
```

From pfSense:

```bash
qm guest exec 124 --timeout 20 -- /bin/sh -c '
  pfctl -sr 2>/dev/null | grep 10.100.0.50
  ifconfig em0
  ifconfig em1
'
```

Watch firewall blocks during a failed connection attempt:

```bash
qm guest exec 124 --timeout 20 -- /bin/sh -c '
  tcpdump -ni em0 host 10.100.0.50 and port 3389
'
```

If packets arrive but no reply is allowed, the WAN rule is still missing or
misordered.

---

## 11. Rollback

### 11.1 Remove the temporary route

If you used the runtime route and have not persisted it:

```bash
qm guest exec 108 --timeout 20 -- bash -c 'ip route del 10.7.0.0/24 via 10.100.0.70 dev ens18'
```

### 11.2 Restore the previous netplan

List the backups:

```bash
qm guest exec 108 --timeout 20 -- bash -c 'ls -l /root/50-cloud-init.yaml.bak-*'
```

Restore the chosen backup:

```bash
qm guest exec 108 --timeout 30 -- bash -c '
  cp -a /root/50-cloud-init.yaml.bak-YYYYMMDD-HHMMSS /etc/netplan/50-cloud-init.yaml
  netplan generate
  netplan apply
'
```

> The previous netplan file was already invalid. If `netplan generate` fails
> after restoring it, use the corrected file from Section 5.2 instead.

### 11.3 Remove the pfSense WAN rules

Delete the `Allow BT7 RDP from Guacamole node2` and optional ICMP rules from
**Firewall > Rules > WAN**, then apply changes.

Do not use `pfctl -d` as a permanent rollback; it disables the entire firewall.

### 11.4 Move connections back to the root

If you need to undo the group layout, use the Guacamole GUI to edit each BT7
connection and set **Location** to `ROOT`, then delete the `BT7-WESCOM` group.
Alternatively:

```sql
UPDATE guacamole_db.guacamole_connection
SET parent_id = NULL
WHERE connection_name IN (
  'BT7-DC','BT7-FileSvr','BT7-WS1','BT7-WS2','BT7-WS3','BT7-WS4'
);
```

---

## 12. Security and Validation Checklist

- [ ] `10.7.0.0/24 via 10.100.0.70` is present in `ip route`.
- [ ] The route is persisted in `/etc/netplan/50-cloud-init.yaml`.
- [ ] pfSense WAN allows only `10.100.0.50/32` to `10.7.0.0/24` on port `3389`.
- [ ] pfSense WAN still blocks all other unsolicited inbound RDP.
- [ ] `blockpriv` remains disabled on the BT7 WAN interface.
- [ ] Guacamole connections are inside the `BT7-WESCOM` group.
- [ ] `guacadmin`, `redteam`, and `guacuser` permissions are correct.
- [ ] All six BT7 connections open from the Guacamole web interface.
- [ ] All six connections still work after rebooting VM 108.
- [ ] No real lab passwords are committed to this repository.
- [ ] Proxmox `8006` is not exposed to untrusted networks.
- [ ] Lab passwords are rotated after the exercise.

---

## 13. Quick Reference

| Action | Command |
| :--- | :--- |
| List VMs | `qm list` |
| Check VM status | `qm status <vmid>` |
| Run command in VM | `qm guest exec <vmid> --timeout 20 -- <command>` |
| Add BT7 route (runtime) | `qm guest exec 108 -- bash -c 'ip route replace 10.7.0.0/24 via 10.100.0.70 dev ens18'` |
| Verify route | `qm guest exec 108 -- bash -c 'ip route get 10.7.0.4'` |
| Allow RDP on pfSense WAN | `qm guest exec 124 -- /usr/local/bin/easyrule pass wan tcp 10.100.0.50 10.7.0.0/24 3389` |
| Test from VM 108 | `qm guest exec 108 -- bash -c 'nc -zv -w 2 10.7.0.4 3389'` |
| Test from guacd | `qm guest exec 108 -- bash -c 'docker exec guacd nc -z -w 3 10.7.0.4 3389'` |
| Guacamole URL | `https://10.2.229.50/guacamole/` |
| Proxy URL | `https://10.2.229.60:8443/guacamole/` |
