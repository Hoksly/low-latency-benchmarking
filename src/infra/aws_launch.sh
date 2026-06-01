#!/bin/bash
# ============================================================
# aws_launch.sh — idempotent testbed provisioner
#
# Safe to run at any time.  Checks the current state of the
# two-instance benchmark cluster and does only what is missing:
#   • Launch instances if they do not exist (or were terminated)
#   • Start instances if they are stopped
#   • Attach benchmark ENIs (ens6) if not yet attached
#   • Disable source/dest check on bench ENIs if still enabled
#   • Configure ens6 inside each guest if not already up
#   • Verify cross-NIC reachability (SUT ↔ GEN over ens6)
#
# On success it prints the public IPs and the exact command to
# hand to run_full_experiment.sh.
#
# Prerequisites:
#   • aws CLI configured (aws configure or IAM role)
#   • jq installed locally
#   • SSH key at KEY_PATH (default: ~/.ssh/diploma-bench-key.pem)
#
# Usage:
#   bash aws_launch.sh [KEY_PATH]
# ============================================================
set -euo pipefail
IFS=$'\n\t'

# ── Persistent resource IDs (created once, never change) ────
REGION=eu-central-1
AZ=eu-central-1c
AMI=ami-0c905937c14bd22b0        # Ubuntu 22.04 LTS, eu-central-1
TYPE=c6in.xlarge
KEY_NAME=diploma-bench-key
SG=sg-0c9126dfcde8159d6          # diploma-bench-sg  (SSH + intra-SG all traffic)
SUBNET=subnet-090c54e24e35e81c9  # 172.31.0.0/20, eu-central-1c
PG=diploma-bench-cluster         # cluster placement group
ENI_SUT=eni-028975f463a1b005a    # bench NIC, 172.31.5.23
ENI_GEN=eni-0d209c9d9fe65c3bd    # bench NIC, 172.31.1.121
SUT_BENCH_IP=172.31.5.23
GEN_BENCH_IP=172.31.1.121

KEY_PATH=${1:-$HOME/.ssh/diploma-bench-key.pem}
SSH_OPTS="-i $KEY_PATH -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"

LOG()  { echo "[$(date +%H:%M:%S)] $*"; }
OK()   { echo "[$(date +%H:%M:%S)] ✓ $*"; }
WARN() { echo "[$(date +%H:%M:%S)] ⚠ $*"; }
DIE()  { echo "ERROR: $*" >&2; exit 1; }

# ── 0. Pre-flight ────────────────────────────────────────────
LOG "Pre-flight checks…"
command -v aws  >/dev/null || DIE "aws CLI not found"
command -v jq   >/dev/null || DIE "jq not found"
aws sts get-caller-identity --region $REGION --output json >/dev/null \
    || DIE "AWS credentials not valid (run: aws configure)"
OK "AWS credentials OK"

# ── Helper: wait for a specific instance state ───────────────
wait_state() {
    local id=$1 target=$2
    LOG "  Waiting for $id → $target…"
    for i in $(seq 1 40); do
        state=$(aws ec2 describe-instances --instance-ids "$id" \
                  --query 'Reservations[0].Instances[0].State.Name' \
                  --output text --region $REGION)
        [ "$state" = "$target" ] && { OK "  $id is $target"; return 0; }
        [ "$state" = "terminated" ] && DIE "$id terminated unexpectedly"
        sleep 10
    done
    DIE "Timed out waiting for $id to reach $target"
}

# ── Helper: wait for SSH to accept connections ───────────────
wait_ssh() {
    local ip=$1 label=$2
    LOG "  Waiting for SSH on $label ($ip)…"
    for i in $(seq 1 24); do
        ssh $SSH_OPTS ubuntu@$ip "true" 2>/dev/null && \
            { OK "  SSH to $label OK"; return 0; }
        sleep 15
    done
    DIE "Timed out waiting for SSH on $label ($ip)"
}

# ── 1. Find existing instances ───────────────────────────────
LOG "Checking for existing instances (tag Project=diploma-bench)…"

get_instance() {
    local role=$1
    aws ec2 describe-instances \
        --filters "Name=tag:Project,Values=diploma-bench" \
                  "Name=tag:Role,Values=$role" \
                  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].[InstanceId] | [0][0]' \
        --output text --region $REGION 2>/dev/null | grep -v 'None' || true
}

SUT_ID=$(get_instance sut)
GEN_ID=$(get_instance gen)

LOG "  SUT: ${SUT_ID:-<not found>}"
LOG "  GEN: ${GEN_ID:-<not found>}"

# ── 2. Ensure placement group exists ─────────────────────────
LOG "Checking placement group '$PG'…"
pg_state=$(aws ec2 describe-placement-groups \
    --group-names "$PG" \
    --query 'PlacementGroups[0].State' \
    --output text --region $REGION 2>/dev/null || echo "missing")
if [ "$pg_state" != "available" ]; then
    LOG "  Creating placement group '$PG' (cluster strategy)…"
    aws ec2 create-placement-group \
        --group-name "$PG" \
        --strategy cluster \
        --region $REGION
    OK "  Placement group created"
else
    OK "  Placement group '$PG' already exists"
fi

# ── 3. Ensure security group exists ──────────────────────────
LOG "Checking security group…"
VPC_ID=$(aws ec2 describe-subnets \
    --subnet-ids "$SUBNET" \
    --query 'Subnets[0].VpcId' \
    --output text --region $REGION)
LOG "  VPC: $VPC_ID"

existing_sg=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=diploma-bench-sg" \
              "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' \
    --output text --region $REGION 2>/dev/null | grep -v 'None' || true)

if [ -n "$existing_sg" ]; then
    SG=$existing_sg
    OK "  Security group already exists: $SG"
else
    LOG "  Creating security group 'diploma-bench-sg'…"
    SG=$(aws ec2 create-security-group \
        --group-name diploma-bench-sg \
        --description "diploma-bench: SSH + intra-group all traffic" \
        --vpc-id "$VPC_ID" \
        --region $REGION \
        --query 'GroupId' --output text)
    # SSH from anywhere
    aws ec2 authorize-security-group-ingress \
        --group-id "$SG" --protocol tcp --port 22 --cidr 0.0.0.0/0 \
        --region $REGION >/dev/null
    # All traffic within the same security group (bench NIC traffic)
    aws ec2 authorize-security-group-ingress \
        --group-id "$SG" --protocol all --port -1 \
        --source-group "$SG" \
        --region $REGION >/dev/null
    OK "  Security group created: $SG"
fi

# ── 4. Ensure SSH key pair exists ────────────────────────────
LOG "Checking key pair '$KEY_NAME'…"
kp_exists=$(aws ec2 describe-key-pairs \
    --key-names "$KEY_NAME" \
    --query 'KeyPairs[0].KeyName' \
    --output text --region $REGION 2>/dev/null | grep -v 'None' || true)

if [ -n "$kp_exists" ] && [ -f "$KEY_PATH" ]; then
    OK "  Key pair '$KEY_NAME' exists and local key file present"
elif [ -n "$kp_exists" ] && [ ! -f "$KEY_PATH" ]; then
    # Key exists in AWS but private key is gone — must recreate
    WARN "  Key pair exists in AWS but local file missing — recreating…"
    aws ec2 delete-key-pair --key-name "$KEY_NAME" --region $REGION
    kp_exists=""
fi

if [ -z "$kp_exists" ]; then
    LOG "  Creating key pair '$KEY_NAME' and saving to $KEY_PATH…"
    mkdir -p "$(dirname "$KEY_PATH")"
    aws ec2 create-key-pair \
        --key-name "$KEY_NAME" \
        --query 'KeyMaterial' \
        --output text \
        --region $REGION > "$KEY_PATH"
    chmod 600 "$KEY_PATH"
    OK "  Key pair created and saved to $KEY_PATH"
fi

# ── 5. Ensure bench ENIs exist ────────────────────────────────
LOG "Checking bench ENIs…"
ensure_eni() {
    local eni_var=$1 ip=$2 label=$3

    # First: look up by private IP — handles the case where the ENI was
    # created in a previous run but the stored ID is stale or wrong.
    found=$(aws ec2 describe-network-interfaces \
        --filters "Name=private-ip-address,Values=$ip" \
                  "Name=subnet-id,Values=$SUBNET" \
        --query 'NetworkInterfaces[0].NetworkInterfaceId' \
        --output text --region $REGION 2>/dev/null | grep -v 'None' || true)

    if [ -n "$found" ]; then
        OK "  $label ENI found by IP ($ip): $found"
        eval "$eni_var=$found"
        return 0
    fi

    # No ENI with that IP — create it
    LOG "  Creating $label bench ENI ($ip)…"
    new_eni=$(aws ec2 create-network-interface \
        --subnet-id "$SUBNET" \
        --private-ip-address "$ip" \
        --groups "$SG" \
        --description "diploma-bench $label benchmark NIC" \
        --region $REGION \
        --query 'NetworkInterface.NetworkInterfaceId' \
        --output text)
    aws ec2 modify-network-interface-attribute \
        --network-interface-id "$new_eni" \
        --no-source-dest-check --region $REGION
    OK "  $label ENI created: $new_eni"
    eval "$eni_var=$new_eni"
}

ensure_eni ENI_SUT "$SUT_BENCH_IP" SUT
ensure_eni ENI_GEN "$GEN_BENCH_IP" GEN

# ── 6. Launch missing instances ──────────────────────────────
launch_one() {
    local role=$1
    LOG "Launching $role instance ($TYPE)…"
    iid=$(aws ec2 run-instances \
        --image-id "$AMI" --instance-type "$TYPE" --count 1 \
        --key-name "$KEY_NAME" \
        --security-group-ids "$SG" \
        --subnet-id "$SUBNET" \
        --placement "GroupName=$PG,AvailabilityZone=$AZ" \
        --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":50,"VolumeType":"gp3"}}]' \
        --tag-specifications \
            "ResourceType=instance,Tags=[{Key=Project,Value=diploma-bench},{Key=Role,Value=$role},{Key=Name,Value=diploma-bench-$role}]" \
        --region "$REGION" \
        --query 'Instances[0].InstanceId' \
        --output text 2>&1) || DIE "Failed to launch $role: $iid"
    [[ "$iid" =~ ^i- ]] || DIE "Launch $role returned unexpected output: $iid"
    OK "Launched $role: $iid"
    echo "$iid"
}

if [ -z "$SUT_ID" ]; then
    SUT_ID=$(launch_one sut)
fi
if [ -z "$GEN_ID" ]; then
    GEN_ID=$(launch_one gen)
fi

# ── 8. Start stopped instances ───────────────────────────────
start_if_stopped() {
    local id=$1 role=$2
    state=$(aws ec2 describe-instances --instance-ids "$id" \
              --query 'Reservations[0].Instances[0].State.Name' \
              --output text --region $REGION)
    if [ "$state" = "stopped" ]; then
        LOG "Starting stopped instance $role ($id)…"
        aws ec2 start-instances --instance-ids "$id" --region $REGION >/dev/null
    fi
}
start_if_stopped "$SUT_ID" sut
start_if_stopped "$GEN_ID" gen

wait_state "$SUT_ID" running
wait_state "$GEN_ID" running

# ── 8. Disable source/dest check on bench ENIs ───────────────
LOG "Checking source/dest check on bench ENIs…"
check_srcdst() {
    local eni=$1
    aws ec2 describe-network-interfaces \
        --network-interface-ids "$eni" \
        --query 'NetworkInterfaces[0].SourceDestCheck' \
        --output text --region $REGION
}
if [ "$(check_srcdst $ENI_SUT)" != "False" ]; then
    LOG "  Disabling src/dst check on ENI_SUT ($ENI_SUT)…"
    aws ec2 modify-network-interface-attribute \
        --network-interface-id "$ENI_SUT" \
        --no-source-dest-check --region $REGION
fi
if [ "$(check_srcdst $ENI_GEN)" != "False" ]; then
    LOG "  Disabling src/dst check on ENI_GEN ($ENI_GEN)…"
    aws ec2 modify-network-interface-attribute \
        --network-interface-id "$ENI_GEN" \
        --no-source-dest-check --region $REGION
fi
OK "Source/dest check disabled on both bench ENIs"

# ── 9. Attach bench ENIs (ens6) if not already attached ──────
attach_if_needed() {
    local eni=$1 instance=$2 role=$3
    eni_state=$(aws ec2 describe-network-interfaces \
        --network-interface-ids "$eni" \
        --query 'NetworkInterfaces[0].Status' \
        --output text --region $REGION)
    attached_to=$(aws ec2 describe-network-interfaces \
        --network-interface-ids "$eni" \
        --query 'NetworkInterfaces[0].Attachment.InstanceId' \
        --output text --region $REGION 2>/dev/null | grep -v 'None' || true)

    if [ "$attached_to" = "$instance" ]; then
        OK "  $eni already attached to $role ($instance)"
        return 0
    fi

    if [ -n "$attached_to" ] && [ "$attached_to" != "$instance" ]; then
        WARN "  $eni is attached to a DIFFERENT instance ($attached_to) — detaching first"
        att_id=$(aws ec2 describe-network-interfaces \
            --network-interface-ids "$eni" \
            --query 'NetworkInterfaces[0].Attachment.AttachmentId' \
            --output text --region $REGION)
        aws ec2 detach-network-interface --attachment-id "$att_id" \
            --region $REGION
        LOG "  Waiting for ENI to become available…"
        for i in $(seq 1 12); do
            st=$(aws ec2 describe-network-interfaces \
                --network-interface-ids "$eni" \
                --query 'NetworkInterfaces[0].Status' \
                --output text --region $REGION)
            [ "$st" = "available" ] && break
            sleep 5
        done
    fi

    LOG "  Attaching $eni to $role ($instance) as device-index 1…"
    aws ec2 attach-network-interface \
        --network-interface-id "$eni" \
        --instance-id "$instance" \
        --device-index 1 \
        --region $REGION >/dev/null
    OK "  $eni attached to $role"
}

LOG "Checking ENI attachment…"
attach_if_needed "$ENI_SUT" "$SUT_ID" sut
attach_if_needed "$ENI_GEN" "$GEN_ID" gen

# Allow OS time to see the new NIC
sleep 8

# ── 10. Get public IPs ────────────────────────────────────────
LOG "Fetching public IPs…"
SUT_PUB=$(aws ec2 describe-instances --instance-ids "$SUT_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text --region $REGION)
GEN_PUB=$(aws ec2 describe-instances --instance-ids "$GEN_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text --region $REGION)
[ -n "$SUT_PUB" ] && [ "$SUT_PUB" != "None" ] || DIE "SUT has no public IP"
[ -n "$GEN_PUB" ] && [ "$GEN_PUB" != "None" ] || DIE "GEN has no public IP"
OK "SUT public IP: $SUT_PUB"
OK "GEN public IP: $GEN_PUB"

# ── 11. Wait for SSH ──────────────────────────────────────────
wait_ssh "$SUT_PUB" SUT
wait_ssh "$GEN_PUB" GEN

# ── 12. Configure ens6 inside guests ─────────────────────────
configure_ens6() {
    local pub=$1 bench_ip=$2 label=$3
    LOG "  Checking ens6 on $label ($pub)…"

    # Check if ens6 exists and already has the right IP
    has_ip=$(ssh $SSH_OPTS ubuntu@$pub \
        "ip addr show ens6 2>/dev/null | grep -c '$bench_ip' || true")
    if [ "$has_ip" -ge 1 ] 2>/dev/null; then
        OK "  ens6 on $label already has $bench_ip"
        return 0
    fi

    LOG "  Configuring ens6 on $label ($bench_ip/20)…"
    ssh $SSH_OPTS ubuntu@$pub "
        set -e
        sudo ip link set ens6 up
        sudo ip addr flush dev ens6 2>/dev/null || true
        sudo ip addr add $bench_ip/20 dev ens6
        echo ens6 configured: \$(ip addr show ens6 | grep 'inet ')
    "
    OK "  ens6 on $label configured"
}

LOG "Configuring ens6 on both instances…"
configure_ens6 "$SUT_PUB" "$SUT_BENCH_IP" SUT
configure_ens6 "$GEN_PUB" "$GEN_BENCH_IP" GEN

# ── 13. Verify all attributes ─────────────────────────────────
echo
LOG "════ Final attribute check ════"

check_instance() {
    local id=$1 pub=$2 bench_ip=$3 eni=$4 label=$5

    # State
    state=$(aws ec2 describe-instances --instance-ids "$id" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text --region $REGION)
    printf "  %-4s %-22s state=%-9s  " "$label" "($id)" "$state"

    # ENI attached
    attached_eni=$(aws ec2 describe-instances --instance-ids "$id" \
        --query 'Reservations[0].Instances[0].NetworkInterfaces[?Attachment.DeviceIndex==`1`].NetworkInterfaceId | [0]' \
        --output text --region $REGION 2>/dev/null | grep -v 'None' || true)
    if [ "$attached_eni" = "$eni" ]; then
        printf "ens6-eni=OK  "
    else
        printf "ens6-eni=MISSING  "
    fi

    # ens6 IP inside guest
    has_ip=$(ssh $SSH_OPTS ubuntu@$pub \
        "ip addr show ens6 2>/dev/null | grep -c '$bench_ip' || true" 2>/dev/null || echo 0)
    if [ "$has_ip" -ge 1 ] 2>/dev/null; then
        printf "ens6-ip=%-15s  " "$bench_ip"
    else
        printf "ens6-ip=MISSING       "
    fi

    # src/dst check on bench ENI
    srcdst=$(check_srcdst "$eni")
    [ "$srcdst" = "False" ] && printf "src/dst-check=OFF\n" \
                             || printf "src/dst-check=ON (should be OFF)\n"
}

check_instance "$SUT_ID" "$SUT_PUB" "$SUT_BENCH_IP" "$ENI_SUT" SUT
check_instance "$GEN_ID" "$GEN_PUB" "$GEN_BENCH_IP" "$ENI_GEN" GEN

# ── 14. Cross-NIC ping ────────────────────────────────────────
LOG "Cross-NIC reachability (SUT ens6 → GEN ens6)…"
ssh $SSH_OPTS ubuntu@$SUT_PUB "ping -c 3 -W 2 $GEN_BENCH_IP > /dev/null" \
    && OK "SUT ($SUT_BENCH_IP) → GEN ($GEN_BENCH_IP): reachable" \
    || WARN "SUT cannot ping GEN over ens6 — check security group / ENI config"

# ── Write env file for run.sh ────────────────────────────────
printf "SUT_PUB=%s\nGEN_PUB=%s\nKEY_PATH=%s\n" \
    "$SUT_PUB" "$GEN_PUB" "$KEY_PATH" > /tmp/bench-ips.env

# ── Done ─────────────────────────────────────────────────────
echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Testbed ready                                               ║"
printf "║  SUT: %-54s  ║\n" "$SUT_PUB  (ens6: $SUT_BENCH_IP)"
printf "║  GEN: %-54s  ║\n" "$GEN_PUB  (ens6: $GEN_BENCH_IP)"
echo "║                                                              ║"
echo "║  Run the full experiment with:                               ║"
printf "║    bash src/infra/run_full_experiment.sh \\\n"
printf "║         %-52s\\\n" "$SUT_PUB $GEN_PUB"
printf "║         %s\n" "$KEY_PATH"
echo "╚══════════════════════════════════════════════════════════════╝"
