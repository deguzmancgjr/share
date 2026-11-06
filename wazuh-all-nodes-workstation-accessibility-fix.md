# Troubleshooting & Resolution: Lab Workstation Accessibility for All 10 Wazuh VMs on `node1` & `node2`

This guide documents the root cause analysis, network addressing plan, step-by-step fix procedures, and end-to-end verification for all 10 Wazuh VMs across **`node1` (`133, 163, 160, 125, 126`)** and **`node2` (`213, 198, 100, 109, 199`)**.

---

## 1. Environment & Complete Wazuh Inventory (`node1` and `node2`)

Every Blue Team (`BT1`–`BT9`, plus `ADO` on `node1`) operates inside a dedicated `/24` subnet (`10.<team>.0.0/24`) on the internal bridge **`vmbr1`**, with the team Wazuh Server assigned to **`.10`** (`10.<team>.0.10/24`) and the team pfSense LAN gateway at **`.1`** (`10.<team>.0.1`).

| Proxmox Node | Team / Unit | Wazuh VM ID | VM Name | NIC / MAC (`vmbr1`) | Previous (Broken) State | Fixed IPv4 Address | Gateway | HTTPS (`443`) & Agent (`1514`/`1515`) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **`node1`** | **BT1 (CYCOM)** | **163** | `BT1-CYCOM-Wazuh` | `BC:24:11:97:D1:06` | `10.1.0.10/24` *(collided with 126 & 133)* | **`10.1.0.10/24`** | `10.1.0.1` | **HTTP 200 / OPEN** |
| **`node1`** | **BT2 (PA)** | **160** | `BT2-PA-Wazuh` | `BC:24:11:42:4C:14` | `10.2.0.10/24` *(`wazuh-indexer` & `manager` failed)* | **`10.2.0.10/24`** | `10.2.0.1` | **HTTP 200 / OPEN** |
| **`node1`** | **BT3 (PN)** | **125** | `BT3-PN-Wazuh` | `BC:24:11:77:84:BA` | `10.3.0.10/24` *(`wazuh-manager` failed)* | **`10.3.0.10/24`** | `10.3.0.1` | **HTTP 200 / OPEN** |
| **`node1`** | **BT4 (PAF)** | **126** | `BT4-PAF-Wazuh` | `BC:24:11:E9:C8:DC` | `10.1.0.10/24` *(wrong subnet)* | **`10.4.0.10/24`** | `10.4.0.1` | **HTTP 200 / OPEN** |
| **`node1`** | **ADO** | **133** | `ADO-Wazuh` | `BC:24:11:73:5B:BB` | `10.1.0.10/24` *(wrong subnet, services failed)* | **`10.5.0.10/24`** | `10.5.0.1` | **HTTP 200 / OPEN** |
| **`node2`** | **BT5 (PCG)** | **213** | `BT5-PCG-Wazuh` | `BC:24:11:1E:F5:E2` | `10.6.0.10/24` *(wrong subnet, services failed)* | **`10.5.0.10/24`** | `10.5.0.1` | **HTTP 200 / OPEN** |
| **`node2`** | **BT6 (DND)** | **198** | `BT6-DND-Wazuh` | `BC:24:11:E5:4A:B9` | `10.6.0.10/24` *(collided with 213, 100, 199; stale lock)* | **`10.6.0.10/24`** | `10.6.0.1` | **HTTP 200 / OPEN** |
| **`node2`** | **BT7 (WESCOM)** | **100** | `BT7-WESCOM-Wazuh` | `BC:24:11:E9:24:AE` | `10.6.0.10/24` *(wrong subnet)* | **`10.7.0.10/24`** | `10.7.0.1` | **HTTP 200 / OPEN** |
| **`node2`** | **BT8 (NOLCOM)** | **109** | `BT8-NOLCOM-Wazuh` | `BC:24:11:E1:6B:30` | `10.8.0.10/24` | **`10.8.0.10/24`** | `10.8.0.1` | **HTTP 200 / OPEN** |
| **`node2`** | **BT9 (STRATCOM)** | **199** | `BT9-STRATCOM-Wazuh` | `BC:24:11:16:F4:B8` | `10.6.0.10/24` *(wrong subnet, services failed)* | **`10.9.0.10/24`** | `10.9.0.1` | **HTTP 200 / OPEN** |

---

## 2. Root Causes Identified

1. **Duplicate / Cloned Netplan IP Addresses Across Subnets on Shared Bridge `vmbr1`**:
   - All 10 Wazuh VMs were cloned from a single Ubuntu 24.04 template (`viscom-wazuh`).
   - On **`node1`**, **VM 163 (`BT1-CYCOM-Wazuh`)**, **VM 126 (`BT4-PAF-Wazuh`)**, and **VM 133 (`ADO-Wazuh`)** were all configured with **`10.1.0.10/24`** simultaneously in `/etc/netplan/50-cloud-init.yaml`, causing ARP collisions in BT1 (`10.1.0.0/24`) and leaving BT4 (`10.4.0.0/24`) and ADO (`10.5.0.0/24` on `node1`) with no Wazuh server at `.10`.
   - On **`node2`**, **VM 213 (`BT5-PCG-Wazuh`)**, **VM 198 (`BT6-DND-Wazuh`)**, **VM 100 (`BT7-WESCOM-Wazuh`)**, and **VM 199 (`BT9-STRATCOM-Wazuh`)** were all configured with **`10.6.0.10/24`** simultaneously on `vmbr1`, causing severe ARP conflicts in BT6 (`10.6.0.0/24`) and leaving BT5 (`10.5.0.0/24`), BT7 (`10.7.0.0/24`), and BT9 (`10.9.0.0/24`) unable to reach their team Wazuh servers.

2. **`wazuh-indexer` and `wazuh-manager` Boot Timeouts (`HTTP 503: Wazuh dashboard server is not ready yet`)**:
   - During simultaneous host boot (`onboot: 1`), `wazuh-indexer` (OpenSearch JVM) and `wazuh-manager` exceeded systemd's default startup timeout and entered a `failed` state with no automatic restart configured on **VMs `160, 125, 133` (`node1`)** and **VMs `213, 198, 199` (`node2`)**.
   - Because `wazuh-indexer` (`127.0.0.1:9200`) or `wazuh-manager` (`55000`, `1514`, `1515`) was stopped, `wazuh-dashboard` (`443`) returned `503 Service Unavailable` (`Wazuh dashboard server is not ready yet`) and workstations could not connect to ports `1514` / `1515`.

3. **Stale Lock Directory & PID Files on `VM 198` (`BT6-DND-Wazuh`)**:
   - On **VM 198**, a stale lock directory (`/var/ossec/var/start-script-lock`) and stale PID files (`/var/ossec/var/run/*.pid`) from an unclean shutdown prevented `wazuh-manager` from starting (`ERROR: Another instance is locking this process`).

---

## 3. Step-by-Step Resolution Procedures (Applied)

### Step 1: Configure Unique Team Netplan IP & Gateway on Each Wazuh VM

On each Wazuh VM (login `analyst` / `password`), configure `/etc/netplan/50-cloud-init.yaml` with the team's `.10` address and `.1` gateway:

| Node | VM ID | VM Name | `<TEAM_IP>` | `<TEAM_GW>` |
| :--- | :--- | :--- | :--- | :--- |
| `node1` | **163** | `BT1-CYCOM-Wazuh` | `10.1.0.10` | `10.1.0.1` |
| `node1` | **160** | `BT2-PA-Wazuh` | `10.2.0.10` | `10.2.0.1` |
| `node1` | **125** | `BT3-PN-Wazuh` | `10.3.0.10` | `10.3.0.1` |
| `node1` | **126** | `BT4-PAF-Wazuh` | `10.4.0.10` | `10.4.0.1` |
| `node1` | **133** | `ADO-Wazuh` | `10.5.0.10` | `10.5.0.1` |
| `node2` | **213** | `BT5-PCG-Wazuh` | `10.5.0.10` | `10.5.0.1` |
| `node2` | **198** | `BT6-DND-Wazuh` | `10.6.0.10` | `10.6.0.1` |
| `node2` | **100** | `BT7-WESCOM-Wazuh` | `10.7.0.10` | `10.7.0.1` |
| `node2` | **109** | `BT8-NOLCOM-Wazuh` | `10.8.0.10` | `10.8.0.1` |
| `node2` | **199** | `BT9-STRATCOM-Wazuh` | `10.9.0.10` | `10.9.0.1` |

```bash
sudo tee /etc/netplan/50-cloud-init.yaml > /dev/null << 'EOF'
network:
  version: 2
  ethernets:
    ens18:
      addresses:
      - "<TEAM_IP>/24"
      routes:
      - to: "default"
        via: "<TEAM_GW>"
      nameservers:
        addresses:
        - 8.8.8.8
        - 1.1.1.1
EOF

sudo chmod 600 /etc/netplan/50-cloud-init.yaml
sudo netplan apply
```

### Step 2: Configure Systemd Auto-Restart Overrides & Start All Wazuh Services

Run the following on each Wazuh VM to prevent boot timeouts, clear any stale lock files, and start `wazuh-indexer`, `wazuh-manager`, and `wazuh-dashboard`:

```bash
for svc in wazuh-indexer wazuh-manager wazuh-dashboard; do
  sudo mkdir -p /etc/systemd/system/${svc}.service.d
  sudo tee /etc/systemd/system/${svc}.service.d/override.conf > /dev/null << 'EOF'
[Service]
TimeoutStartSec=300
Restart=on-failure
RestartSec=10
EOF
done

# Clean any stale wazuh-control lock before starting wazuh-manager
sudo rm -rf /var/ossec/var/start-script-lock
sudo systemctl daemon-reload
sudo systemctl restart wazuh-indexer
sudo systemctl restart wazuh-manager
sudo systemctl restart wazuh-dashboard
```

### Step 3: Flush Stale ARP Cache on Lab Workstations (If Needed After IP Conflict Removal)

If a Windows workstation cached a stale MAC address for `10.<team>.0.10` from the previous duplicate-IP collision, run in PowerShell (as Administrator):

```powershell
arp -d *
Test-Connection -ComputerName 10.<team>.0.10 -Count 2
Test-NetConnection -ComputerName 10.<team>.0.10 -Port 443
Test-NetConnection -ComputerName 10.<team>.0.10 -Port 1514
Test-NetConnection -ComputerName 10.<team>.0.10 -Port 1515
```

---

## 4. Live Verification Results

### 4.1 Wazuh Service & Port Verification (`node1` and `node2`)

| Node | VM ID | VM Name | IPv4 Address | `https://<ip>/app/login` | Port `1514` (Agent) | Port `1515` (Enrollment) | Port `9200` (Indexer) | Port `55000` (API) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **`node1`** | **163** | `BT1-CYCOM-Wazuh` | `10.1.0.10` | **`HTTP 200 OK`** | **`OPEN`** | **`OPEN`** | `LISTEN` | `LISTEN` |
| **`node1`** | **160** | `BT2-PA-Wazuh` | `10.2.0.10` | **`HTTP 200 OK`** | **`OPEN`** | **`OPEN`** | `LISTEN` | `LISTEN` |
| **`node1`** | **125** | `BT3-PN-Wazuh` | `10.3.0.10` | **`HTTP 200 OK`** | **`OPEN`** | **`OPEN`** | `LISTEN` | `LISTEN` |
| **`node1`** | **126** | `BT4-PAF-Wazuh` | `10.4.0.10` | **`HTTP 200 OK`** | **`OPEN`** | **`OPEN`** | `LISTEN` | `LISTEN` |
| **`node1`** | **133** | `ADO-Wazuh` | `10.5.0.10` | **`HTTP 200 OK`** | **`OPEN`** | **`OPEN`** | `LISTEN` | `LISTEN` |
| **`node2`** | **213** | `BT5-PCG-Wazuh` | `10.5.0.10` | **`HTTP 200 OK`** | **`OPEN`** | **`OPEN`** | `LISTEN` | `LISTEN` |
| **`node2`** | **198** | `BT6-DND-Wazuh` | `10.6.0.10` | **`HTTP 200 OK`** | **`OPEN`** | **`OPEN`** | `LISTEN` | `LISTEN` |
| **`node2`** | **100** | `BT7-WESCOM-Wazuh` | `10.7.0.10` | **`HTTP 200 OK`** | **`OPEN`** | **`OPEN`** | `LISTEN` | `LISTEN` |
| **`node2`** | **109** | `BT8-NOLCOM-Wazuh` | `10.8.0.10` | **`HTTP 200 OK`** | **`OPEN`** | **`OPEN`** | `LISTEN` | `LISTEN` |
| **`node2`** | **199** | `BT9-STRATCOM-Wazuh` | `10.9.0.10` | **`HTTP 200 OK`** | **`OPEN`** | **`OPEN`** | `LISTEN` | `LISTEN` |

### 4.2 End-to-End Workstation / Subnet Accessibility Verification

| Proxmox Node | Team / Subnet | Source Workstation / Host | Target Wazuh VM | Target IP | ICMP `Ping` | HTTPS Dashboard (`443`) | Agent (`1514`) | Enrollment (`1515`) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **`node1`** | **BT1 (`10.1.0.0/24`)** | `VM 151` (`BT1-CYCOM-WS1`) | **VM 163** (`BT1-CYCOM-Wazuh`) | `10.1.0.10` | **`True`** | **`True` (`HTTP 200`)** | **`True`** | **`True`** |
| **`node1`** | **BT2 (`10.2.0.0/24`)** | `VM 140` (`BT2-PA-WS2`) | **VM 160** (`BT2-PA-Wazuh`) | `10.2.0.10` | **`True`** | **`True` (`HTTP 200`)** | **`True`** | **`True`** |
| **`node1`** | **BT3 (`10.3.0.0/24`)** | `VM 141` (`BT3-PN-WS1`) | **VM 125** (`BT3-PN-Wazuh`) | `10.3.0.10` | **`True`** | **`True` (`HTTP 200`)** | **`True`** | **`True`** |
| **`node1`** | **BT4 (`10.4.0.0/24`)** | `VM 136` (`BT4-PAF-DC`) / `WS1–3` | **VM 126** (`BT4-PAF-Wazuh`) | `10.4.0.10` | **`True`** | **`True` (`HTTP 200`)** | **`True`** | **`True`** |
| **`node1`** | **ADO (`10.5.0.0/24`)** | `VM 102` / `ADO-PFSENSE (116)` | **VM 133** (`ADO-Wazuh`) | `10.5.0.10` | **`True`** | **`True` (`HTTP 200`)** | **`True`** | **`True`** |
| **`node2`** | **BT5 (`10.5.0.0/24`)** | `VM 145` (`BT5-PCG-WS1`) | **VM 213** (`BT5-PCG-Wazuh`) | `10.5.0.10` | **`True`** | **`True` (`HTTP 200`)** | **`True`** | **`True`** |
| **`node2`** | **BT6 (`10.6.0.0/24`)** | `VM 148` (`BT6-DND-WS2`) | **VM 198** (`BT6-DND-Wazuh`) | `10.6.0.10` | **`True`** | **`True` (`HTTP 200`)** | **`True`** | **`True`** |
| **`node2`** | **BT7 (`10.7.0.0/24`)** | `VM 166` (`BT7-WESCOM-WS3`) | **VM 100** (`BT7-WESCOM-Wazuh`) | `10.7.0.10` | **`True`** | **`True` (`HTTP 200`)** | **`True`** | **`True`** |
| **`node2`** | **BT8 (`10.8.0.0/24`)** | `VM 186` (`BT8-NOLCOM-WS1`) | **VM 109** (`BT8-NOLCOM-Wazuh`) | `10.8.0.10` | **`True`** | **`True` (`HTTP 200`)** | **`True`** | **`True`** |
| **`node2`** | **BT9 (`10.9.0.0/24`)** | `VM 185` (`BT9-STRATCOM-WS1`) | **VM 199** (`BT9-STRATCOM-Wazuh`) | `10.9.0.10` | **`True`** | **`True` (`HTTP 200`)** | **`True`** | **`True`** |
