#!/bin/bash
# ==============================================================================
# CYDEX EXERCISE LIFECYCLE CONTROLLER: AJEX RT-PLAYBOOK-001
# Target Cluster: Node 1 (10.2.229.9)
# Managed VMIDs: 170 (Kali), 135 (pfSense), 175 (DC), 153 (FileSvr), 151 (WS1)
# ==============================================================================

set -eo pipefail

SNAPSHOT_TAG="RT-BASE-CLEAN"
VM_LIST=(170 135 175 153 151)
TIMEOUT_SECS=60

function print_header() {
    echo -e "\n===================================================================="
    echo -e " [CYDEX] $1"
    echo -e "===================================================================="
}

function verify_vms_exist() {
    for vmid in "${VM_LIST[@]}"; do
        if ! qm status "$vmid" &>/dev/null; then
            echo "[-] Error: VMID $vmid does not exist on this Proxmox node!"
            exit 1
        fi
    done
}

function create_baseline() {
    print_header "CREATING ATOMIC BASELINE SNAPSHOTS [$SNAPSHOT_TAG]"
    verify_vms_exist
    
    for vmid in "${VM_LIST[@]}"; do
        VM_NAME=$(qm config "$vmid" | grep -m1 '^name:' | awk '{print $2}')
        echo "[*] Processing VMID $vmid ($VM_NAME)..."
        
        # Check if snapshot already exists
        if qm listsnapshot "$vmid" | grep -qw "$SNAPSHOT_TAG"; then
            echo "    [!] Snapshot $SNAPSHOT_TAG already exists on $vmid. Deleting old baseline..."
            qm delsnapshot "$vmid" "$SNAPSHOT_TAG"
        fi
        
        echo "    [+] Taking live snapshot: $SNAPSHOT_TAG (with RAM state)..."
        qm snapshot "$vmid" "$SNAPSHOT_TAG" --vmstate 1 --description "AJEX Clean Pre-Exercise Baseline"
    done
    echo "[✓] All target VMs cleanly snapshotted under tag '$SNAPSHOT_TAG'."
}

function rollback_exercise() {
    print_header "RAPID ROLLBACK: RESTORING TO CLEAN BASELINE [<60s]"
    verify_vms_exist
    
    START_TIME=$(date +%s)
    PIDS=()
    
    for vmid in "${VM_LIST[@]}"; do
        (
            echo "[*] Initiating parallel rollback for VMID $vmid to $SNAPSHOT_TAG..."
            qm rollback "$vmid" "$SNAPSHOT_TAG" --start 1
            echo "[✓] VMID $vmid rollback and power-up complete."
        ) &
        PIDS+=($!)
    done
    
    # Wait for all background rollbacks to complete
    for pid in "${PIDS[@]}"; do
        wait "$pid"
    done
    
    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))
    
    echo -e "\n[✓] Exercise Enclave Reverted in $ELAPSED seconds (Limit: ${TIMEOUT_SECS}s)."
    audit_status
}

function audit_status() {
    print_header "ENCLAVE HEALTH & TELEMETRY AUDIT"
    printf "%-8s %-22s %-12s %-18s\n" "VMID" "HOSTNAME" "STATUS" "SNAPSHOT CONFIRMED"
    printf "%-8s %-22s %-12s %-18s\n" "----" "--------" "------" "------------------"
    
    for vmid in "${VM_LIST[@]}"; do
        VM_NAME=$(qm config "$vmid" | grep -m1 '^name:' | awk '{print $2}')
        STATUS=$(qm status "$vmid" | awk '{print $2}')
        HAS_SNAP="NO"
        if qm listsnapshot "$vmid" | grep -qw "$SNAPSHOT_TAG"; then
            HAS_SNAP="YES"
        fi
        printf "%-8s %-22s %-12s %-18s\n" "$vmid" "$VM_NAME" "$STATUS" "$HAS_SNAP"
    done
}

case "$1" in
    baseline)
        create_baseline
        ;;
    rollback)
        rollback_exercise
        ;;
    audit)
        audit_status
        ;;
    *)
        echo "Usage: $0 {baseline|rollback|audit}"
        echo "  baseline : Create pristine 'RT-BASE-CLEAN' snapshot across target VMs."
        echo "  rollback : Instantly revert all target VMs to clean state in parallel (<60s)."
        echo "  audit    : Audit current VM power state and snapshot status."
        exit 1
        ;;
esac
