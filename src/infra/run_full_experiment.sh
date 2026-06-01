#!/bin/bash
# ============================================================
# run_full_experiment.sh — end-to-end AWS benchmark driver
#
# Provision  →  Install  →  Benchmark (all 9 scenarios)  →  Report
#
# Usage:
#   bash run_full_experiment.sh <SUT_PUBLIC_IP> <GEN_PUBLIC_IP> [KEY_PATH]
#
# Example:
#   bash run_full_experiment.sh 3.72.14.5 3.72.20.8 ~/.ssh/diploma-bench-key.pem
#
# The script runs from your LOCAL machine and orchestrates both
# AWS instances over SSH.  SUT = server under test, GEN = traffic
# generator.  Both must already be running (use aws_launch.sh first)
# and have their benchmark ENI (ens6) attached and configured.
#
# Estimated wall-clock time:
#   Installation:   40–50 min (Seastar build dominates)
#   All benchmarks: ~25 min
# ============================================================
set -euo pipefail
IFS=$'\n\t'

# ── Configuration ────────────────────────────────────────────
SUT_PUB=${1:?Usage: $0 <SUT_PUBLIC_IP> <GEN_PUBLIC_IP> [KEY_PATH]}
GEN_PUB=${2:?Usage: $0 <SUT_PUBLIC_IP> <GEN_PUBLIC_IP> [KEY_PATH]}
KEY=${3:-$HOME/.ssh/diploma-bench-key.pem}

SUT_BENCH_IP=172.31.5.23     # ens6 static private IP — SUT
GEN_BENCH_IP=172.31.1.121    # ens6 static private IP — GEN
RESULTS_LOCAL="$(pwd)/results-$(date +%Y%m%d-%H%M%S)"
SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # src/ root

SSH_OPTS="-i $KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SCP_OPTS="-i $KEY -o StrictHostKeyChecking=no -r"

# ── Helpers ──────────────────────────────────────────────────
LOG()  { echo "[$(date +%H:%M:%S)] $*"; }
STEP() { echo; echo "════════════════════════════════════════"; echo "  $*"; echo "════════════════════════════════════════"; }
S()    { ssh $SSH_OPTS ubuntu@$SUT_PUB "$@"; }
G()    { ssh $SSH_OPTS ubuntu@$GEN_PUB "$@"; }
SBG()  { ssh $SSH_OPTS ubuntu@$SUT_PUB "$@" & }   # SUT background
GBG()  { ssh $SSH_OPTS ubuntu@$GEN_PUB "$@" & }   # GEN background

die() { echo "ERROR: $*" >&2; exit 1; }

# ── 0. Pre-flight checks ─────────────────────────────────────
STEP "0. Pre-flight"
[ -f "$KEY" ] || die "Key not found: $KEY"
chmod 600 "$KEY"

LOG "Checking SSH to SUT ($SUT_PUB)…"
S "echo SUT-OK" || die "Cannot SSH to SUT"
LOG "Checking SSH to GEN ($GEN_PUB)…"
G "echo GEN-OK" || die "Cannot SSH to GEN"

LOG "Checking bench-NIC connectivity from SUT to GEN…"
S "ping -c 3 -W 2 $GEN_BENCH_IP > /dev/null" || \
    die "SUT ens6 ($SUT_BENCH_IP) cannot reach GEN ens6 ($GEN_BENCH_IP)"

mkdir -p "$RESULTS_LOCAL"
LOG "Local results dir: $RESULTS_LOCAL"

# ── 1. Upload src/ to both instances ─────────────────────────
STEP "1. Uploading source tree"
LOG "Uploading to SUT…"
scp $SCP_OPTS "$SRC_DIR" ubuntu@$SUT_PUB:/tmp/bench-src &
SCP_SUT_PID=$!
LOG "Uploading to GEN…"
scp $SCP_OPTS "$SRC_DIR" ubuntu@$GEN_PUB:/tmp/bench-src
wait $SCP_SUT_PID
LOG "Upload done."

# ── 2. Install dependencies (parallel on both) ───────────────
STEP "2. Installation"

LOG "Starting install on GEN (background)…"
GBG "sudo bash /tmp/bench-src/setup/setup_all.sh gen 2>&1 | tee /tmp/setup_gen.log"
GEN_SETUP_PID=$!

LOG "Starting install on SUT…"
S "sudo bash /tmp/bench-src/setup/setup_all.sh sut 2>&1 | tee /tmp/setup_sut.log"
LOG "SUT base install done. Building Seastar (takes ~25 min)…"
S "sudo bash /tmp/bench-src/setup/setup_seastar.sh 2>&1 | tee /tmp/setup_seastar.log"

LOG "Waiting for GEN install to finish…"
wait $GEN_SETUP_PID
LOG "GEN install done."

# Verify installs
LOG "SUT install summary:"
S "tail -5 /tmp/setup_sut.log; tail -3 /tmp/setup_seastar.log" || true
LOG "GEN install summary:"
G "tail -5 /tmp/setup_gen.log" || true

# ── 3. Benchmarks ────────────────────────────────────────────
STEP "3. Benchmarks"
S "mkdir -p /tmp/results"
G "mkdir -p /tmp/gen-results"

# Helper: upload an inline Python script to GEN and run it
gen_py() {
    local name=$1; shift
    G "python3 - $@" << 'PYEOF'
PYEOF
}

# ── S1: Kernel baseline ──────────────────────────────────────
LOG "S1: Kernel baseline"
S "pkill sockperf iperf3 2>/dev/null; sleep 1; true"
S "tmux new-session -d -s s1sck 'sockperf server -i $SUT_BENCH_IP -p 11111'" 2>/dev/null || true
S "iperf3 -s -B $SUT_BENCH_IP -p 5201 -D"
sleep 2

G "sockperf ping-pong -i $SUT_BENCH_IP -p 11111 -m 64 -t 35 2>&1" \
    > "$RESULTS_LOCAL/s1_lat_64b.txt"

G "iperf3 -c $SUT_BENCH_IP -B $GEN_BENCH_IP -p 5201 -u -b 6G -l 64 -t 20 -J 2>&1" \
    > "$RESULTS_LOCAL/s1_pps_64b.json"
G "iperf3 -c $SUT_BENCH_IP -B $GEN_BENCH_IP -p 5201 -u -b 6G -l 512 -t 20 -J 2>&1" \
    > "$RESULTS_LOCAL/s1_pps_512b.json"
G "iperf3 -c $SUT_BENCH_IP -B $GEN_BENCH_IP -p 5201 -u -b 6G -l 1400 -t 20 -J 2>&1" \
    > "$RESULTS_LOCAL/s1_bw_1400b.json"

S "pkill sockperf iperf3 2>/dev/null; sleep 1; true"
LOG "S1 done."

# ── S2: Tuned kernel ─────────────────────────────────────────
LOG "S2: Tuned kernel"
S "sysctl -w net.core.busy_poll=50 net.core.busy_read=50 >/dev/null; \
   ethtool -C ens6 adaptive-rx off rx-usecs 0 tx-usecs 0 2>/dev/null || true; \
   tmux new-session -d -s s2sck 'taskset -c 1 sockperf server -i $SUT_BENCH_IP -p 11112'"
sleep 2

G "taskset -c 1 sockperf ping-pong -i $SUT_BENCH_IP -p 11112 -m 64 -t 35 2>&1" \
    > "$RESULTS_LOCAL/s2_lat_64b.txt"

S "pkill sockperf 2>/dev/null; sleep 1; true"
S "sysctl -w net.core.busy_poll=0 net.core.busy_read=0 >/dev/null"
LOG "S2 done."

# ── S3: io_uring ─────────────────────────────────────────────
LOG "S3: io_uring"
S "pkill iouring-udp-echo 2>/dev/null; \
   tmux new-session -d -s s3iou 'sudo /usr/local/bin/iouring-udp-echo $SUT_BENCH_IP 11113 > /tmp/iou.log 2>&1'"
sleep 3

G "python3 /tmp/bench-src/bench/rtt_latency.py \
    $SUT_BENCH_IP 11113 --count 10000 --warmup 200 --size 64 2>&1" \
    > "$RESULTS_LOCAL/s3_lat_64b.txt"

S "pkill iouring-udp-echo 2>/dev/null; sleep 1; true"
LOG "S3 done."

# ── S4: eBPF XDP_DROP (throughput) ───────────────────────────
LOG "S4: eBPF/XDP_DROP"
S "ethtool -L ens6 combined 2 2>/dev/null || true"
S "ip link set ens6 xdp off 2>/dev/null; \
   ip link set ens6 xdp obj /tmp/xdp_drop.o sec xdp 2>&1 || \
   ip link set ens6 xdpgeneric obj /tmp/xdp_drop.o sec xdp 2>&1"
S "ip link show ens6 | grep prog/xdp || echo 'XDP load status unknown'"

RX0=$(S "ethtool -S ens6 2>/dev/null | grep 'queue_0_rx_cnt:' | awk '{print \$2}'" || echo 0)
LOG "  GEN flood starting (30 s)…"
GBG "python3 /tmp/bench-src/bench/udp_flood.py $SUT_BENCH_IP 9999 --seconds 30 --size 60"
sleep 32
RX1=$(S "ethtool -S ens6 2>/dev/null | grep 'queue_0_rx_cnt:' | awk '{print \$2}'" || echo 0)
DELTA=$(( RX1 - RX0 ))
echo "XDP_DROP PPS: $((DELTA/30))  (${DELTA} pkts / 30 s)" \
    | tee "$RESULTS_LOCAL/s4_xdp_pps.txt"

S "ip link set ens6 xdp off 2>/dev/null || true"
S "ethtool -L ens6 combined 4 2>/dev/null || true"
LOG "S4 done."

# ── S5: AF_XDP (copy mode) ────────────────────────────────────
LOG "S5: AF_XDP via DPDK PMD"
S "ip link set ens6 xdp off 2>/dev/null; rm -rf /var/run/dpdk/"
S "tmux new-session -d -s s5axdp \
   'sudo dpdk-testpmd -l 0-1 -n 2 \
    --vdev=\"net_af_xdp0,iface=ens6,start_queue=0,queue_count=1\" \
    -- --nb-cores=1 --forward-mode=rxonly --rxq=1 --txq=1 --rxd=4096 \
    --stats-period 5 2>&1 | tee /tmp/afxdp.log'"
sleep 8
# Check it started
S "grep -m1 '' /tmp/afxdp.log 2>/dev/null | head -1" || true

LOG "  GEN flood starting (30 s)…"
GBG "python3 /tmp/bench-src/bench/udp_flood.py $SUT_BENCH_IP 9999 --seconds 30 --size 60"
sleep 33

S "grep 'Rx-pps' /tmp/afxdp.log 2>/dev/null | grep -v ':            0' | tail -5 \
   || echo 'no rx-pps stats'" \
    | tee "$RESULTS_LOCAL/s5_afxdp_pps.txt"
S "tmux kill-session -t s5axdp 2>/dev/null; sleep 2; true"
LOG "S5 done."

# ── S6: DPDK testpmd ─────────────────────────────────────────
LOG "S6: DPDK testpmd"
PCI=$(S "basename \$(readlink -f /sys/class/net/ens6/device 2>/dev/null) 2>/dev/null || \
         dpdk-devbind.py --status 2>/dev/null | grep ens6 | awk '{print \$1}' | head -1")
[ -n "$PCI" ] || die "Could not detect ens6 PCI address on SUT"
LOG "  ens6 PCI: $PCI"

# Bind to igb_uio for DPDK
S "ip link set ens6 down 2>/dev/null; dpdk-devbind.py --bind=igb_uio $PCI 2>&1 || true"
S "rm -rf /var/run/dpdk/"

# Start SUT in mac-swap mode (reflects packets back to GEN)
S "tmux new-session -d -s s6sut \
   'sudo dpdk-testpmd -l 0-1 -n 2 -a $PCI \
    --vdev=\"net_af_xdp_dummy\" --no-pci 2>/dev/null || \
    sudo dpdk-testpmd -l 0-1 -n 2 -a $PCI \
    -- --nb-cores=1 --forward-mode=macswap --rxq=1 --txq=1 \
       --rxd=512 --txd=512 --stats-period 5 2>&1 | tee /tmp/dpdk_mac.log'"
sleep 6

# Latency via raw-socket prober on GEN (reaches DPDK mac-swap)
SUT_MAC=$(S "cat /sys/class/net/ens6/address 2>/dev/null || echo ''")
GEN_MAC=$(G "cat /sys/class/net/ens6/address 2>/dev/null || echo ''")
LOG "  Measuring DPDK latency (SUT MAC=$SUT_MAC, GEN MAC=$GEN_MAC)…"

G "python3 - '$SUT_BENCH_IP' '$SUT_MAC' '$GEN_MAC' ens6" << 'RAWPY' \
    > "$RESULTS_LOCAL/s6_dpdk_lat.txt" 2>&1
import sys, socket, struct, time, statistics, os

dst_ip, dst_mac_str, src_mac_str, iface = sys.argv[1:]

def mac_bytes(s):
    return bytes(int(x, 16) for x in s.split(':'))

src_mac = mac_bytes(src_mac_str) if ':' in src_mac_str else b'\x00'*6
dst_mac = mac_bytes(dst_mac_str) if ':' in dst_mac_str else b'\x00'*6

# Raw Ethernet socket (sends and receives ALL frames on iface)
s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0800))
s.bind((iface, 0))
s.settimeout(0.5)

src_ip = socket.inet_aton('172.31.1.121')
dst_ip_b = socket.inet_aton(dst_ip)

def build_udp_frame(seq):
    # Ethernet header
    eth = dst_mac + src_mac + b'\x08\x00'
    # IP header (no options, TTL=64, proto=UDP=17)
    ip_id = seq & 0xFFFF
    ip_hdr = struct.pack('!BBHHHBBH4s4s',
        0x45, 0, 42, ip_id, 0, 64, 17, 0, src_ip, dst_ip_b)
    # IP checksum
    def cksum(d):
        if len(d) % 2: d += b'\x00'
        s = sum(struct.unpack('!'+str(len(d)//2)+'H', d))
        while s >> 16: s = (s & 0xFFFF) + (s >> 16)
        return ~s & 0xFFFF
    ip_hdr = ip_hdr[:10] + struct.pack('!H', cksum(ip_hdr)) + ip_hdr[12:]
    # UDP
    udp = struct.pack('!HHHH', 9999, 9999, 22, 0) + b'\xAB' * 14
    return eth + ip_hdr + udp

warmup = 200
measure = 10000
rtts = []; lost = 0

for i in range(warmup + measure):
    pkt = build_udp_frame(i)
    t0 = time.perf_counter()
    s.send(pkt)
    try:
        while True:
            data = s.recv(2048)
            # Accept any frame with our dst MAC in src field (mac-swapped back)
            if len(data) >= 6 and data[6:12] == dst_mac:
                break
    except socket.timeout:
        if i >= warmup:
            lost += 1
        continue
    if i >= warmup:
        rtts.append((time.perf_counter() - t0) * 1e6)

n = len(rtts)
if n == 0:
    print("ERROR: no replies received — is SUT DPDK mac-swap running?")
    sys.exit(1)
rtts.sort()
print(f"DPDK mac-swap RTT (N={n+lost}, lost={lost})")
print(f"avg-latency = {statistics.mean(rtts):.3f} usec")
print(f"std-dev     = {statistics.stdev(rtts):.3f} usec")
print(f"percentile 50.000 = {rtts[n//2]:.3f}")
print(f"percentile 99.000 = {rtts[int(0.99*n)]:.3f}")
print(f"percentile 99.900 = {rtts[int(0.999*n)]:.3f}")
RAWPY

# PPS (SUT rxonly, GEN flood)
S "tmux kill-session -t s6sut 2>/dev/null; sleep 2; true"
S "rm -rf /var/run/dpdk/"
S "tmux new-session -d -s s6rx \
   'sudo dpdk-testpmd -l 0-1 -n 2 -a $PCI \
    -- --nb-cores=1 --forward-mode=rxonly --rxq=1 --txq=1 \
       --rxd=512 --txd=512 --stats-period 5 2>&1 | tee /tmp/dpdk_rx.log'"
sleep 5

LOG "  GEN flood for DPDK PPS (30 s)…"
GBG "python3 /tmp/bench-src/bench/udp_flood.py $SUT_BENCH_IP 9999 --seconds 30 --size 60"
sleep 33

S "grep 'Rx-pps' /tmp/dpdk_rx.log 2>/dev/null | grep -v ':            0' | tail -5 \
   || echo 'no rx-pps stats'" \
    | tee "$RESULTS_LOCAL/s6_dpdk_pps.txt"
S "tmux kill-session -t s6rx 2>/dev/null; sleep 2; true"

# Rebind ens6 back to kernel driver
S "dpdk-devbind.py --bind=ena $PCI 2>/dev/null || \
   dpdk-devbind.py --bind=kernel $PCI 2>/dev/null || true"
S "ip link set ens6 up; ip addr add $SUT_BENCH_IP/20 dev ens6 2>/dev/null || true"
LOG "S6 done."

# ── S7: VPP host-interface ────────────────────────────────────
LOG "S7: VPP (AF_PACKET host-interface)"
S "pkill vpp 2>/dev/null; sleep 2; rm -f /run/vpp/cli.sock; \
   vpp -c /etc/vpp/startup.conf > /tmp/vpp.log 2>&1 &"
sleep 6

S "vppctl create host-interface name ens6 2>&1; \
   vppctl set int state host-ens6 up 2>&1; \
   vppctl set int ip address host-ens6 $SUT_BENCH_IP/20 2>&1" || true

VCL_LIB=$(S "find /usr/lib -name 'libvcl_ldpreload.so' 2>/dev/null | head -1")
if [ -n "$VCL_LIB" ]; then
    S "cat > /tmp/vcl.conf << 'VCL'
vcl {
  heapsize 64M
  segment-size 268435456
  rx-fifo-size 4000000
  tx-fifo-size 4000000
  app-proxy-transport-udp
}
VCL"
    S "LD_PRELOAD=$VCL_LIB VCL_CONFIG=/tmp/vcl.conf \
        sockperf server -i $SUT_BENCH_IP -p 11116 > /tmp/vpp_vcl.log 2>&1 &"
else
    S "sockperf server -i $SUT_BENCH_IP -p 11116 > /tmp/vpp_sck.log 2>&1 &"
fi
sleep 3

G "sockperf ping-pong -i $SUT_BENCH_IP -p 11116 -m 64 -t 35 2>&1" \
    > "$RESULTS_LOCAL/s7_vpp_lat_64b.txt"

S "pkill sockperf vpp 2>/dev/null; sleep 1; true"
LOG "S7 done."

# ── S8: F-Stack UDP echo ──────────────────────────────────────
LOG "S8: F-Stack"
PCI2=$(S "basename \$(readlink -f /sys/class/net/ens6/device 2>/dev/null) || echo ''")
if S "test -x /usr/local/bin/ff_udp_echo"; then
    S "ip link set ens6 down 2>/dev/null; \
       dpdk-devbind.py --bind=igb_uio $PCI2 2>/dev/null || true"
    S "cat > /etc/f-stack.conf << FFCONF
[dpdk]
lcore_mask=0x4
channel=4
promiscuous=1
nb_mem_channels=4

[port0]
addr=$SUT_BENCH_IP
netmask=255.255.240.0
broadcast=172.31.15.255
gateway=172.31.0.1
FFCONF"
    S "tmux new-session -d -s s8ff \
       'sudo /usr/local/bin/ff_udp_echo --conf /etc/f-stack.conf \
        -- -l 2 -n 4 2>&1 | tee /tmp/fstack.log'"
    sleep 6
    # F-Stack echo on port 11114; measure with Python RTT from GEN
    G "python3 /tmp/bench-src/bench/rtt_latency.py \
        $SUT_BENCH_IP 11114 --count 10000 --warmup 200 --size 64 2>&1" \
        > "$RESULTS_LOCAL/s8_fstack_lat_64b.txt"
    S "tmux kill-session -t s8ff 2>/dev/null; sleep 2; true"
    S "dpdk-devbind.py --bind=ena $PCI2 2>/dev/null || true"
    S "ip link set ens6 up; ip addr add $SUT_BENCH_IP/20 dev ens6 2>/dev/null || true"
    LOG "S8 done."
else
    LOG "S8: ff_udp_echo not found — skipped"
    echo "F-Stack: binary not compiled" > "$RESULTS_LOCAL/s8_fstack_lat_64b.txt"
fi

# ── S9: Seastar ───────────────────────────────────────────────
LOG "S9: Seastar"
SEASTAR_ECHO=$(S "find /usr/local/bin /opt/seastar -name 'seastar-echo' -o -name '*echo*' \
                  -type f 2>/dev/null | head -1" || echo "")
if [ -n "$SEASTAR_ECHO" ]; then
    PCI3=$(S "basename \$(readlink -f /sys/class/net/ens6/device 2>/dev/null) || echo ''")
    S "ip link set ens6 down 2>/dev/null; \
       dpdk-devbind.py --bind=igb_uio $PCI3 2>/dev/null || true"
    S "tmux new-session -d -s s9sea \
       'sudo $SEASTAR_ECHO \
        --network-stack native --dpdk-port-index 0 --smp 2 \
        --host-ipv4-addr $SUT_BENCH_IP \
        --gw-ipv4-addr 172.31.0.1 \
        --netmask-ipv4-addr 255.255.240.0 \
        --dhcp false 2>&1 | tee /tmp/seastar.log'"
    sleep 10
    S "head -3 /tmp/seastar.log" || true

    G "python3 /tmp/bench-src/bench/rtt_latency.py \
        $SUT_BENCH_IP 10000 --count 10000 --warmup 200 --size 64 2>&1" \
        > "$RESULTS_LOCAL/s9_seastar_lat_64b.txt"

    # PPS
    GBG "python3 /tmp/bench-src/bench/udp_flood.py \
             $SUT_BENCH_IP 10000 --seconds 30 --size 60"
    sleep 3
    S "grep 'packets' /tmp/seastar.log 2>/dev/null | tail -3 \
       || grep -i 'pps\|received' /tmp/seastar.log 2>/dev/null | tail -3 \
       || echo 'no pps line in seastar log'" \
        > "$RESULTS_LOCAL/s9_seastar_pps.txt"
    wait

    S "tmux kill-session -t s9sea 2>/dev/null; sleep 2; true"
    S "dpdk-devbind.py --bind=ena $PCI3 2>/dev/null || true"
    S "ip link set ens6 up; ip addr add $SUT_BENCH_IP/20 dev ens6 2>/dev/null || true"
    LOG "S9 done."
else
    LOG "S9: Seastar echo binary not found — skipped"
    echo "Seastar: binary not found" > "$RESULTS_LOCAL/s9_seastar_lat_64b.txt"
fi

# ── 4. Collect extra artefacts from SUT ──────────────────────
STEP "4. Collecting artefacts"
S "tar czf /tmp/raw-results.tgz /tmp/results/ /tmp/afxdp.log /tmp/dpdk_rx.log \
          /tmp/dpdk_mac.log /tmp/vpp.log /tmp/fstack.log /tmp/seastar.log \
          /tmp/iou.log 2>/dev/null; true"
scp $SCP_OPTS ubuntu@$SUT_PUB:/tmp/raw-results.tgz "$RESULTS_LOCAL/" 2>/dev/null || true
LOG "Raw artefacts saved to $RESULTS_LOCAL/raw-results.tgz"

# ── 5. Parse and print results table ─────────────────────────
STEP "5. Results"

python3 << PYEOF
import os, re, json, glob

RES = "$RESULTS_LOCAL"

# ── Helpers ──────────────────────────────────────────────────
def read(path):
    try:
        return open(path).read()
    except FileNotFoundError:
        return ""

def sockperf_lat(text):
    """Return (avg_us, p50_us, p99_us) from sockperf output."""
    avg = re.search(r'avg-latency\s*=\s*([\d.]+)', text)
    p50 = re.search(r'percentile 50\.000\s*=\s*([\d.]+)', text)
    p99 = re.search(r'percentile 99\.000\s*=\s*([\d.]+)', text)
    if avg and p50 and p99:
        return float(avg.group(1)), float(p50.group(1)), float(p99.group(1))
    return None, None, None

def py_lat(text):
    """Same format but from our Python rtt_latency.py."""
    return sockperf_lat(text)  # identical output format

def iperf_pps(path):
    """Return avg PPS from iperf3 -J output (UDP sender stats)."""
    try:
        d = json.load(open(path))
        pkts = d['end']['sum']['packets']
        secs = d['end']['sum']['seconds']
        return int(pkts / secs)
    except Exception:
        return None

def iperf_mbps(path):
    """Return Mbps from iperf3 -J output."""
    try:
        d = json.load(open(path))
        return round(d['end']['sum']['bits_per_second'] / 1e6, 0)
    except Exception:
        return None

def dpdk_pps(text):
    """Return max Rx-pps line from dpdk-testpmd stats."""
    vals = re.findall(r'Rx-pps:\s+(\d+)', text)
    if vals:
        return max(int(v) for v in vals)
    return None

def xdp_pps(text):
    m = re.search(r'XDP_DROP PPS:\s*(\d+)', text)
    return int(m.group(1)) if m else None

# ── Load data ────────────────────────────────────────────────
s1_lat   = sockperf_lat(read(f"{RES}/s1_lat_64b.txt"))
s1_pps64 = iperf_pps(f"{RES}/s1_pps_64b.json")
s1_pps512 = iperf_pps(f"{RES}/s1_pps_512b.json")
s1_mbps  = iperf_mbps(f"{RES}/s1_bw_1400b.json")

s2_lat   = sockperf_lat(read(f"{RES}/s2_lat_64b.txt"))

s3_lat   = py_lat(read(f"{RES}/s3_lat_64b.txt"))

s4_pps   = xdp_pps(read(f"{RES}/s4_xdp_pps.txt"))

s5_pps   = dpdk_pps(read(f"{RES}/s5_afxdp_pps.txt"))

s6_lat   = py_lat(read(f"{RES}/s6_dpdk_lat.txt"))
s6_pps   = dpdk_pps(read(f"{RES}/s6_dpdk_pps.txt"))

s7_lat   = sockperf_lat(read(f"{RES}/s7_vpp_lat_64b.txt"))

s8_lat   = py_lat(read(f"{RES}/s8_fstack_lat_64b.txt"))

s9_lat   = py_lat(read(f"{RES}/s9_seastar_lat_64b.txt"))

def fmt(v, unit="", fallback="—"):
    if v is None:
        return fallback
    if isinstance(v, float):
        return f"{v:.1f}{unit}"
    return f"{v}{unit}"

def lat_row(label, tup, pps=None, extra=""):
    avg, p50, p99 = tup if tup else (None, None, None)
    pps_s = fmt(pps, " pps") if pps else extra
    return (f"  {label:<28} {fmt(avg,'µs'):>9} {fmt(p50,'µs'):>9} "
            f"{fmt(p99,'µs'):>9}   {pps_s}")

W = 80
print()
print("=" * W)
print(f"  BENCHMARK RESULTS — {os.path.basename(RES)}")
print("=" * W)
print(f"  {'Scenario':<28} {'avg lat':>9} {'P50':>9} {'P99':>9}   Throughput")
print("-" * W)
print(lat_row("S1 kernel baseline",      s1_lat,  s1_pps64,
              f"{fmt(s1_pps64,'pps')} / {fmt(s1_mbps,'Mbps')}"))
print(lat_row("S2 tuned kernel",         s2_lat))
print(lat_row("S3 io_uring",             s3_lat))
print(f"  {'S4 eBPF/XDP_DROP':<28} {'—':>9} {'—':>9} {'—':>9}   {fmt(s4_pps,'pps')}")
print(f"  {'S5 AF_XDP (copy)':<28} {'—':>9} {'—':>9} {'—':>9}   {fmt(s5_pps,'pps')}")
print(lat_row("S6 DPDK testpmd",         s6_lat,  s6_pps))
print(lat_row("S7 VPP AF_PACKET",        s7_lat))
print(lat_row("S8 F-Stack",              s8_lat))
print(lat_row("S9 Seastar native DPDK",  s9_lat))
print("=" * W)
print(f"  Full data saved to: {RES}/")
print("=" * W)
print()
PYEOF

LOG "Done. All results in: $RESULTS_LOCAL"
