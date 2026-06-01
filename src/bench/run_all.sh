#!/bin/bash
# ============================================================
# Complete benchmark runner — all 9 technologies
# Run on SUT after aws_setup_all.sh + Seastar install
# Usage: bash aws_benchmark_all.sh
# ============================================================
SUT_IP=172.31.5.23   # ens6 SUT
GEN_IP=172.31.1.121  # ens6 GEN
KEY=~/.ssh/diploma-bench-key.pem
GEN_HOST=<GEN_PUBLIC_IP>   # fill in
LOG() { echo "[$(date +%H:%M:%S)] $*"; }
S() { ssh -i $KEY -o StrictHostKeyChecking=no ubuntu@$GEN_HOST "$@"; }
mkdir -p /tmp/results

# ── Verify connectivity ─────────────────────────────────────
ping -c 2 $GEN_IP > /dev/null 2>&1 || { echo "ERROR: no ping to GEN ens6"; exit 1; }

# ── S1: Kernel baseline ─────────────────────────────────────
LOG "S1 kernel baseline"
pkill sockperf 2>/dev/null; sleep 1
tmux new-session -d -s s1 "sockperf server -i $SUT_IP -p 11111"
sleep 2
S "sockperf ping-pong -i $SUT_IP -p 11111 -m 64 -t 35 2>&1" > /tmp/results/s1_lat_64b.txt
S "iperf3 -c $SUT_IP -B $GEN_IP -p 5202 -u -b 6G -l 64 -t 20 -J 2>&1" > /tmp/results/s1_pps_64b.json
S "iperf3 -c $SUT_IP -B $GEN_IP -p 5202 -u -b 6G -l 512 -t 20 -J 2>&1" > /tmp/results/s1_pps_512b.json
iperf3 -s -B $SUT_IP -p 5202 -D
pkill sockperf 2>/dev/null

# ── S2: Tuned kernel ────────────────────────────────────────
LOG "S2 tuned kernel"
sysctl -w net.core.busy_poll=50 >/dev/null
ethtool -C ens6 adaptive-rx off rx-usecs 0 tx-usecs 0 2>/dev/null || true
tmux new-session -d -s s2 "taskset -c 1 sockperf server -i $SUT_IP -p 11112"
sleep 2
S "taskset -c 1 sockperf ping-pong -i $SUT_IP -p 11112 -m 64 -t 35 2>&1" > /tmp/results/s2_lat_64b.txt
pkill sockperf 2>/dev/null

# ── S3: io_uring ────────────────────────────────────────────
LOG "S3 io_uring"
tmux new-session -d -s s3 "sudo /usr/local/bin/iouring-udp-echo $SUT_IP 11113 > /tmp/iou.log 2>&1"
sleep 3
# Verify server is up
python3 -c "
import socket, time
s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(2.0)
s.sendto(b'ping',('$SUT_IP',11113))
try: d,_=s.recvfrom(64); print('io_uring echo OK')
except: print('ERROR: io_uring server not responding')
"
# Measure latency with Python RTT (sockperf protocol incompatible with simple echo)
python3 << 'PYEOF' | tee /tmp/results/s3_lat_64b.txt
import socket, time, statistics
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(1.0)
ip, port = "172.31.5.23", 11113
pkt = b'A' * 64

# Warmup
for i in range(200):
    s.sendto(pkt, (ip, port))
    try: s.recvfrom(64)
    except: pass

# Measure 10000 packets
rtts = []; lost = 0
for i in range(10000):
    t0 = time.perf_counter()
    s.sendto(pkt, (ip, port))
    try:
        s.recvfrom(64)
        rtts.append((time.perf_counter()-t0)*1e6)
    except: lost += 1

if rtts:
    rtts.sort(); n = len(rtts)
    print(f"io_uring UDP echo latency (N={len(rtts)+lost})")
    print(f"avg-latency = {statistics.mean(rtts):.3f} usec")
    print(f"std-dev     = {statistics.stdev(rtts):.3f} usec")
    print(f"percentile 50.000 = {rtts[n//2]:.3f}")
    print(f"percentile 99.000 = {rtts[int(0.99*n)]:.3f}")
    print(f"percentile 99.900 = {rtts[int(0.999*n)]:.3f}")
    print(f"lost = {lost}/{len(rtts)+lost}")
PYEOF
pkill iouring-udp-echo 2>/dev/null; tmux kill-session -t s3 2>/dev/null

# ── S4: eBPF/XDP_DROP ───────────────────────────────────────
LOG "S4 eBPF XDP_DROP"
# Reduce channels to 2 for XDP native mode on ENA
ethtool -L ens6 combined 2 2>/dev/null || true
# Load XDP_DROP program
ip link set ens6 xdp off 2>/dev/null || true
bpftool link detach id $(bpftool link list 2>/dev/null | grep "ifindex ens6" | awk '{print $1}' | tr -d ':') 2>/dev/null || true
ip link set ens6 xdp obj /tmp/xdp_drop.o sec xdp 2>&1
ip link show ens6 | grep "prog/xdp" && echo "XDP_DROP loaded" || echo "XDP_DROP load FAILED"

# Record RX counter before flood
RX0=$(ethtool -S ens6 2>/dev/null | grep 'queue_0_rx_cnt:' | awk '{print $2}')
LOG "  Waiting for GEN flood (30s)..."
# [GEN should send: python3 -c 'import socket,time; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.setsockopt(socket.SOL_SOCKET,socket.SO_SNDBUF,1<<20); pkt=b"A"*60; t=time.time(); c=0\nwhile time.time()-t<30: s.sendto(pkt,("172.31.5.23",9999)); c+=1\nprint(f"{c} pkts = {c//30} pps")']
sleep 32
RX1=$(ethtool -S ens6 2>/dev/null | grep 'queue_0_rx_cnt:' | awk '{print $2}')
DELTA=$((RX1 - RX0))
echo "XDP_DROP: $((DELTA/30)) PPS ($DELTA packets / 30s)" | tee /tmp/results/s4_ebpf.txt
ip link set ens6 xdp off 2>/dev/null || true

# ── S5: AF_XDP (DPDK PMD, ens6 must be kernel NIC) ─────────
LOG "S5 AF_XDP via DPDK PMD"
# Ensure ens6 is on kernel driver (no XDP programs)
bpftool net show dev ens6 2>/dev/null
# Try AF_XDP PMD — needs libbpf 1.4.6 (installed above) and DPDK rebuilt against it
rm -rf /var/run/dpdk/
tmux new-session -d -s s5 "sudo dpdk-testpmd -l 0-1 -n 2 \
  --vdev='net_af_xdp0,iface=ens6,start_queue=0,queue_count=1' \
  -- --nb-cores=1 --forward-mode=rxonly --rxq=1 --txq=1 --rxd=4096 \
  --stats-period 5 2>&1 | tee /tmp/afxdp.log"
sleep 8
head -5 /tmp/afxdp.log | grep -v "^EAL"
# [GEN sends flood to SUT ens6 for 25s]
sleep 28
grep "Rx-pps" /tmp/afxdp.log | grep -v ':            0' | tail -3 | tee -a /tmp/results/s5_afxdp.txt
tmux kill-session -t s5 2>/dev/null

# ── S6: DPDK testpmd ────────────────────────────────────────
LOG "S6 DPDK"
# Bind ens6 to igb_uio
PCI=$(basename $(readlink -f /sys/class/net/ens6/device 2>/dev/null) 2>/dev/null || \
      dpdk-devbind.py --status 2>/dev/null | grep ens6 | awk '{print $1}' | head -1)
[ -n "$PCI" ] && ip link set ens6 down && dpdk-devbind.py --bind=igb_uio $PCI

rm -rf /var/run/dpdk/
tmux new-session -d -s s6rx "sudo dpdk-testpmd -l 0-1 -n 2 -a $PCI \
  -- --nb-cores=1 --forward-mode=rxonly --rxq=1 --txq=1 --rxd=4096 \
  --stats-period 5 2>&1 | tee /tmp/dpdk_rx.log"
sleep 5
# [GEN: dpdk-testpmd txonly targeting SUT MAC and IP]
sleep 25
grep "Rx-pps" /tmp/dpdk_rx.log | grep -v ':            0' | tail -3 | tee /tmp/results/s6_dpdk.txt
tmux kill-session -t s6rx 2>/dev/null

# ── S7: VPP host-interface ──────────────────────────────────
LOG "S7 VPP"
# Rebind ens6 back to kernel
dpdk-devbind.py --bind=ena $PCI 2>/dev/null || true
ip link set ens6 up
ip addr flush dev ens6 2>/dev/null
ip addr add $SUT_IP/20 dev ens6

pkill vpp 2>/dev/null; sleep 2; rm -f /run/vpp/cli.sock
vpp -c /etc/vpp/startup.conf &
sleep 6
# Create host-interface (correct VPP 26.x syntax)
vppctl create host-interface name ens6 2>&1 | tee /tmp/vpp_iface.log
vppctl set int state host-ens6 up 2>&1
vppctl set int ip address host-ens6 $SUT_IP/20 2>&1
vppctl show interface 2>&1 | head -8 | tee /tmp/results/s7_vpp_iface.txt

# VPP latency via VCL LD_PRELOAD
VCL_LIB=$(find /usr/lib -name 'libvcl_ldpreload.so' 2>/dev/null | head -1)
if [ -n "$VCL_LIB" ]; then
    cat > /tmp/vcl.conf << 'VCLEOF'
vcl {
  heapsize 64M
  segment-size 268435456
  rx-fifo-size 4000000
  tx-fifo-size 4000000
  app-proxy-transport-udp
  app-proxy-transport-tcp
}
VCLEOF
    LD_PRELOAD=$VCL_LIB VCL_CONFIG=/tmp/vcl.conf \
        sockperf server -i $SUT_IP -p 11116 > /tmp/vpp_vcl.log 2>&1 &
    sleep 3
    # [GEN: sockperf ping-pong -i $SUT_IP -p 11116 -m 64 -t 35 > results/s7_lat.txt]
    LOG "VPP VCL server started on port 11116"
fi

# ── S8: F-Stack UDP echo ────────────────────────────────────
LOG "S8 F-Stack"
# F-Stack needs DPDK PMD for NIC access
PCI2=$(basename $(readlink -f /sys/class/net/ens6/device 2>/dev/null))
ip link set ens6 down 2>/dev/null
dpdk-devbind.py --bind=igb_uio $PCI2 2>/dev/null || true

# F-Stack config
cat > /etc/f-stack.conf << FFCONF
[dpdk]
lcore_mask=0x4
channel=4
promiscuous=1
nb_mem_channels=4

[port0]
addr=$SUT_IP
netmask=255.255.240.0
broadcast=172.31.15.255
gateway=172.31.0.1
FFCONF

# Run F-Stack echo server (if compiled)
if [ -x /usr/local/bin/ff_udp_echo ]; then
    tmux new-session -d -s s8 "sudo /usr/local/bin/ff_udp_echo --conf /etc/f-stack.conf \
      -- -l 0 -n 4 2>&1 | tee /tmp/fstack.log"
    sleep 5
    head -3 /tmp/fstack.log
    LOG "F-Stack echo server started on port 11114"
fi

# ── S9: Seastar (if built) ──────────────────────────────────
LOG "S9 Seastar"
SEASTAR_ECHO=$(find /opt/seastar /tmp/seastar -name "*echo*" -type f 2>/dev/null | head -1)
if [ -n "$SEASTAR_ECHO" ]; then
    tmux new-session -d -s s9 "sudo $SEASTAR_ECHO \
      --network-stack native --dpdk-port-index 0 --smp 2 \
      --host-ipv4-addr $SUT_IP \
      --gw-ipv4-addr 172.31.0.1 \
      --netmask-ipv4-addr 255.255.240.0 \
      --dhcp false \
      2>&1 | tee /tmp/seastar.log"
    sleep 10
    head -3 /tmp/seastar.log
else
    LOG "Seastar echo binary not found — skip"
fi

LOG "=== All scenarios launched ==="
LOG "Results dir: /tmp/results/"
ls -la /tmp/results/
