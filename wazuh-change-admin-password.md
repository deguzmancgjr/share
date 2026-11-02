# Step-by-Step Guide: Changing the Admin Password in Wazuh

This guide provides detailed, step-by-step procedures for changing the administrative credentials in a Wazuh deployment.

---

## 1. Overview of Wazuh Administrative Accounts

A standard Wazuh deployment has two primary administrative users:

| Account | Role | Authentication Layer | Configuration Location |
| :--- | :--- | :--- | :--- |
| **`admin`** | Web Dashboard & Indexer Administrator | Wazuh Indexer (OpenSearch Security) | `/etc/wazuh-indexer/opensearch-security/internal_users.yml` |
| **`wazuh`** | Wazuh Manager API Administrator | Wazuh Manager API | `/var/ossec/api/configuration/api.yaml` |

Choose the method below that best fits your environment and access level.

---

## 2. Method 1: Using the Official CLI Password Tool (Recommended)

Wazuh provides a dedicated password management script on the server that securely hashes and updates credentials without manual file editing.

### Step 2.1: Access the Wazuh Server
Log into your Wazuh server via SSH or the Proxmox web console as `root`:
```bash
ssh root@<WAZUH_SERVER_IP>
```

### Step 2.2: Run the Password Update Tool
Execute the `wazuh-passwords-tool.sh` utility, specifying the `admin` user and your desired password:

```bash
bash /usr/share/wazuh-indexer/plugins/opensearch-security/tools/wazuh-passwords-tool.sh \
  -u admin \
  -p 'YourStrongPassword123!'
```

> [!TIP]
> **Password Complexity Requirements**:
> Use at least 8 characters containing uppercase letters, lowercase letters, numbers, and special symbols (e.g., `!@#$%^&*`). Avoid using single quotes `'` inside the password string when running from the bash terminal.

### Step 2.3: (Optional) Auto-Generate a Random Password
If you prefer Wazuh to generate a secure random password:
```bash
bash /usr/share/wazuh-indexer/plugins/opensearch-security/tools/wazuh-passwords-tool.sh -u admin
```
*Note down the generated password displayed in the terminal output.*

---

## 3. Method 2: Via the Wazuh Web Dashboard (GUI)

If you are currently logged in with administrative rights and prefer a graphical interface:

### Step 3.1: Open Internal Users
1. Log into your Wazuh Web Dashboard (`https://<WAZUH_IP>/`).
2. Click the **Main Menu** icon (☰) in the upper-left corner.
3. Scroll down to **Indexer management** and click **Security**.
4. In the Security left sidebar, click **Internal users**.

### Step 3.2: Edit the `admin` User
1. Locate **`admin`** in the user list and click on the name.
2. Click the **Edit user** button in the upper-right corner.
3. Enter your new password in the **Password** field.
4. Re-enter the same password in the **Repeat password** field.
5. Click **Save changes** (or **Submit**).

---

## 4. Method 3: Manual Hash Generation & `securityadmin.sh`

Use this method if the automated tool is unavailable or if you need to perform an offline recovery:

### Step 4.1: Generate the Password Hash
Run the built-in bcrypt hashing script:
```bash
bash /usr/share/wazuh-indexer/plugins/opensearch-security/tools/hash.sh -p 'YourStrongPassword123!'
```
**Example Output**:
```text
$2y$12$e8Yk1J5Vw3Z2rB9qQ7xOzeP1mL4sX8vR3jK6wF0tM5uN7pL9qY1a2
```
*Copy the entire output string starting with `$2y$`.*

### Step 4.2: Update `internal_users.yml`
Open the internal users configuration file in a text editor:
```bash
nano /etc/wazuh-indexer/opensearch-security/internal_users.yml
```

Locate the `admin:` block at the top of the file:
```yaml
admin:
  hash: "$2y$12$e8Yk1J5Vw3Z2rB9qQ7xOzeP1mL4sX8vR3jK6wF0tM5uN7pL9qY1a2"
  reserved: true
  backend_roles:
  - "admin"
  description: "Admin user"
```
Replace the existing `hash:` string with your newly generated hash. Save and exit (<kbd>Ctrl</kbd> + <kbd>O</kbd>, then <kbd>Ctrl</kbd> + <kbd>X</kbd>).

### Step 4.3: Apply Changes to the Indexer
Run the `securityadmin.sh` script to load the configuration into the active OpenSearch cluster:

```bash
export JAVA_HOME=/usr/share/wazuh-indexer/jdk/

bash /usr/share/wazuh-indexer/plugins/opensearch-security/tools/securityadmin.sh \
  -cd /etc/wazuh-indexer/opensearch-security/ \
  -icl -nhnv \
  -cacert /etc/wazuh-indexer/certs/root-ca.pem \
  -cert /etc/wazuh-indexer/certs/admin.pem \
  -key /etc/wazuh-indexer/certs/admin-key.pem
```

**Expected Confirmation**:
```text
Done with success
```

---

## 5. Changing the Wazuh API Administrator (`wazuh`)

If you want to change the password used to access the **Wazuh Manager REST API** (default user `wazuh`):

### Step 5.1: Run the API Password Utility
```bash
cd /var/ossec/api/scripts
python3 wazuh-apipass-tool.py -u wazuh -p 'YourNewApiPassword123!'
```

### Step 5.2: Restart the Wazuh Manager
```bash
systemctl restart wazuh-manager
```

### Step 5.3: Update API Credentials in the Dashboard
If your dashboard connects to the API using this account:
1. Open the Wazuh Dashboard in your browser.
2. Go to **Settings** (gear icon) > **API configuration**.
3. Edit the API entry and update the password.
4. Click **Save** and verify the connection test passes.

---

## 6. Verification & Health Checks

### Test 1: Verify Indexer Authentication via CLI
Run the following `curl` command against the local indexer:
```bash
curl -k -u admin:'YourStrongPassword123!' https://localhost:9200
```
**Expected Response**:
```json
{
  "name" : "wazuh-indexer",
  "cluster_name" : "wazuh-cluster",
  "version" : {
    "number" : "7.10.2",
    "distribution" : "opensearch"
  },
  "tagline" : "The OpenSearch Project: https://opensearch.org/"
}
```

### Test 2: Verify Web Dashboard Access
1. Open a private / incognito browser window.
2. Navigate to:
   ```
   https://<WAZUH_SERVER_IP>/
   ```
3. Sign in with:
   * **Username**: `admin`
   * **Password**: `YourStrongPassword123!`
4. Verify you land on the Wazuh overview screen without errors.

---

## 7. Troubleshooting

| Symptom / Error | Root Cause | Solution |
| :--- | :--- | :--- |
| `Cannot connect to https://localhost:9200` | The `wazuh-indexer` service is stopped. | Run `systemctl start wazuh-indexer` and wait 30 seconds for the Java heap to initialize. |
| `OpenSearch-Security not initialized` | `securityadmin.sh` was not executed after editing `internal_users.yml`. | Re-run the `securityadmin.sh` command from Section 4.3 with root certificates. |
| `Unauthorized / 401` on Dashboard | The dashboard config (`kibanaserver`) was inadvertently modified. | Ensure only the `admin` password was updated. If you changed `kibanaserver`, update `/etc/wazuh-dashboard/opensearch_dashboards.yml` and restart `wazuh-dashboard`. |
| `Permission denied` on tool | Script executed without root privileges. | Run command with `sudo` or switch to `root` (`sudo -i`). |
