### 1. CONTEXT
I operate an on-premises, multi-tenant cyber defense training and detection engineering cyber range hosted across a dual-node Proxmox VE 8.x hypervisor cluster (`node1` at 10.2.229.9 and `node2` at 10.2.229.10; 188 GiB RAM per node). The cluster utilizes a three-tier network architecture:
- Tier 0: Out-of-band Management Plane (`vmbr0` on physical network 10.2.229.0/24) with dual Apache Guacamole HTML5 bastions (VM 102 and VM 108).
- Tier 1: Exercise Transit Backbone (`vmbr1` on 10.100.0.0/24, isolated Layer 2 per node) housing Core pfSense routers (VM 119 on Node 1, VM 132 on Node 2) and a 12-node Kali Linux Red Team attack fleet (VMs 170, 117, 127, 134 on Node 1; VMs 131, 111, 110, 201, 221-224 on Node 2).
- Tier 2: Nine isolated Blue Team military command enclaves (BT1 through BT9, subnets 10.1.0.0/24 to 10.9.0.0/24), each fronted by a dedicated virtual pfSense router, Active Directory Domain Controller, File Server, and Windows Workstations.

I need to operationalize and run the exercise "Spearphishing to Data Exfiltration" (Exercise ID: RT-PLAYBOOK-001) inside this realistic infrastructure without disrupting the cluster or inducing routing drops.

### 2. TASK
Generate an end-to-end operational engineering and detection-validation runbook tailored specifically to this CYDEX Proxmox lab environment. The guide must detail:
1. Target Enclave Mapping: Bind the playbook's generic targets directly to an active enclave—specifically targeting Blue Team 1 (BT1 - CYCOM on Node 1: subnet 10.1.0.0/24, DC VM 175, File Server VM 153, WS1 VM 151) attacked by RedTeam0 (Kali VM 170 on Node 1: transit IP 10.100.0.80).
2. Network & Routing Configuration: Exact pfSense firewall rules, NAT, and port forwards needed across Core pfSense (VM 119) and BT1 pfSense (VM 135) to route traffic from the transit backbone into the internal enclave while strictly avoiding upstream gateway traps on LAN interfaces (`LANGW`) and asymmetric routing on multi-homed hosts.
3. Telemetry Pipeline Hardening: Configuration of the centralized Wazuh SIEM Manager (VM 198: 10.6.0.10 on Node 2) to collect Sysmon, Windows Event Logs (EID 4688 with CLI), WinRM, OpenSSH, and PowerShell Script Block logs (EID 4104) from the BT1 endpoints.
4. Step-by-Step Scenario Execution & Alert Matrix: Exact terminal commands and PowerShell scripts to execute Scenarios 1 through 6 from RT-PLAYBOOK-001 against BT1, mapped to the exact Wazuh rule IDs, Sysmon Event IDs, and pfSense state tables expected.
5. Snapshot & Rapid Teardown Automation: Native Proxmox CLI scripts (`qm`) to baseline, audit, and revert the entire attack path within 60 seconds.

### 3. INPUT (Cluster & Playbook Parameters)
- Cluster Inventory & Mapping:
  * Red Team Node: RedTeam0 (VMID 170, Node 1, IP: `10.100.0.80/24` on `vmbr1`, Guacamole Connection ID: 10)
  * Target Enclave: BT1 - CYCOM (`cycom.local`, Subnet: `10.1.0.0/24` on `vmbr1`)
  * Enclave Gateway/Firewall: `BT1-CYCOM-PFSENSE` (VMID 135, WAN: `10.100.0.10/24`, LAN: `10.1.0.1/24`, Upstream GW: `10.100.0.1`)
  * Initial Access Target: `BT1-CYCOM-WS1` (VMID 151, IP: `10.1.0.4/24`, Gateway: `10.1.0.1`, DNS: `10.1.0.2`)
  * Lateral Movement Target: `BT1-CYCOM-FileSvr` (VMID 153, IP: `10.1.0.3/24`, Gateway: `10.1.0.1`, Domain: `cycom.local`)
  * Central SIEM / EDR: `BT6-DND-Wazuh` (VMID 198, Node 2, IP: `10.6.0.10/24`, Agent listener: TCP 1514, API: TCP 55000)
  * Remote Management: Apache Guacamole Node 1 (VMID 102, Mgmt: `10.2.229.60`, Transit: `10.100.0.60`)
- Architectural Guardrails:
  * `vmbr1` Layer 2 Boundary: Layer 2 broadcast domains do not cross between Node 1 and Node 2. Inter-node telemetry from BT1 on Node 1 reaching Wazuh (VM 198) on Node 2 must traverse the routing architecture or management plane.
  * pfSense Gateway Rules: LAN interfaces (`em1`) must have IPv4 Upstream Gateway set to **None**. Outbound NAT must be set to Hybrid/Automatic translating `10.1.0.0/24` to WAN address `10.100.0.10`.
  * Multi-Homed Policy Routing: Ensure Guacamole VM 102 routing tables enforce default routes via `vmbr0` (`10.2.229.1`) with metric 100 and transit routes via `10.100.0.1` with metric 200 to prevent asymmetric packet drops.
- Playbook Scenarios (RT-PLAYBOOK-001):
  * Scenario 1: Phishing simulation with callback listener on Kali `TCP 4445` from `BT1-CYCOM-WS1` (`10.1.0.4`).
  * Scenario 2: Credential discovery via `credentials.txt` on WS1 and validation of OpenSSH on port `TCP 22`.
  * Scenario 3: Subnet reconnaissance (`nmap`) of `10.1.0.0/24` from Kali across the transit bridge.
  * Scenario 4: Benign artifact delivery via Kali HTTP server (`TCP 8000`), download via `certutil.exe`/`curl.exe`, and persistence via `schtasks`.
  * Scenario 5: Lateral movement from WS1 to File Server (`10.1.0.3`) via WinRM (`TCP 5985/5986`).
  * Scenario 6: Collection of synthetic `Top_Secret.pdf` and exfiltration to Kali (`10.100.0.80`) with SHA-256 validation.

### 4. OUTPUT CONSTRAINTS
- Production-Ready Technical Depth: Provide fully qualified, copy-pasteable configuration files, pfSense WebGUI/CLI rules, PowerShell snippets, and Proxmox `qm` commands. Avoid conceptual summaries.
- Structure of the Deliverable:
  * Section 1: Network Ingress/Egress & pfSense Port Forwarding Blueprint (Specific NAT/firewall rules to route RedTeam0 `10.100.0.80` traffic to BT1 endpoints `10.1.0.x`).
  * Section 2: Windows Endpoint Telemetry Configuration (Sysmon installation commands with SwiftOnSecurity XML schema, Local Group Policy audit adjustments for EID 4688 CLI logging, and `ossec.conf` blocks pointing to Wazuh at `10.6.0.10`).
  * Section 3: Step-by-Step Tactical Execution Guide (Executing Scenarios 1 to 6 with exact IPs, synthetic paths, and target services).
  * Section 4: Detection & Alert Validation Matrix (A markdown table pairing: Scenario Phase | Artifact/Command Executed | Event Source | Event ID / Log Channel | Expected Wazuh Rule ID & Description).
  * Section 5: Automated Proxmox Lifecycle & Snapshot Runbook (Bash script using `qm snapshot` and `qm rollback` targeting VMIDs 170, 135, 175, 153, 151 with tag `RT-BASE-CLEAN`).

### 5. REVIEWER (Quality Assurance & Validation Standards)
Evaluate the completed operational guide against:
- Topology Accuracy: Are all IPs, VMIDs, hostnames, and domain names (`cycom.local`) 100% compliant with the CYDEX Master Systems Inventory?
- Routing Feasibility: Does the guide respect the Layer 2 boundary between `node1` and `node2`, ensuring telemetry reaches Wazuh VM 198 without broken routes?
- Behavioral Detection Integrity: Does the telemetry setup successfully log process command-line arguments, scheduled task creation, network connections, and file access without flooding the Wazuh indexer?
- Operational Isolation: Does all Red Team simulation traffic stay strictly confined to `vmbr1` and enclave subnets without leaking out to physical management `vmbr0`?