#!/bin/bash
# ============================================================
# Complete AWS benchmark setup script
# Tested locally via Docker (Ubuntu 22.04)
# Run as: sudo bash aws_setup_all.sh [sut|gen]
# ============================================================
set -e
ROLE=${1:-sut}  # 'sut' = receiver, 'gen' = generator
LOG() { echo "[$(date +%H:%M:%S)] $*"; }
export DEBIAN_FRONTEND=noninteractive

LOG "=== Role: $ROLE ==="

# ── 0. Base packages ─────────────────────────────────────────
LOG "Installing base packages..."
apt-get update -qq
apt-get install -y -qq \
  build-essential gcc-12 g++-12 git python3-pip meson ninja-build pkg-config \
  linux-headers-$(uname -r) libnuma-dev libssl-dev libpcre3-dev \
  libelf-dev zlib1g-dev clang llvm \
  iperf3 sockperf numactl hwloc stow \
  cmake ragel protobuf-compiler libprotobuf-dev \
  libboost-all-dev libyaml-cpp-dev libhwloc-dev \
  libcrypto++-dev libfmt-dev liblz4-dev libsctp-dev \
  libgnutls28-dev libnl-3-dev libnl-route-3-dev \
  2>&1 | tail -5
pip3 install pyelftools --quiet
update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 100
update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-12 100

# Hugepages
echo 1024 > /proc/sys/vm/nr_hugepages
echo "vm.nr_hugepages=1024" >> /etc/sysctl.conf

# CPU governor
for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -f "$f" ] && echo performance > "$f"
done || true

LOG "Base packages done."

# ── 1. F-Stack with bundled DPDK 23.11 ──────────────────────
LOG "=== Building F-Stack (bundled DPDK 23.11) ==="
cd /tmp && rm -rf f-stack
git clone https://github.com/F-Stack/f-stack --depth=1 -q

# Build F-Stack's own DPDK (avoids API incompatibility with system DPDK 24.11)
cd /tmp/f-stack/dpdk
meson setup build --buildtype=release \
  -Dprefix=/opt/fstack-dpdk \
  -Denable_kmods=false \
  -Dtests=false \
  -Dexamples='' \
  -Ddisable_drivers='net/mlx4,net/mlx5,common/mlx5,compress/mlx5,regex/mlx5,vdpa/mlx5' \
  2>&1 | tail -5
ninja -C build -j$(nproc) 2>&1 | tail -5
ninja -C build install > /dev/null 2>&1
LOG "F-Stack DPDK done."

# Build F-Stack lib
cd /tmp/f-stack/lib
export FF_PATH=/tmp/f-stack
export PKG_CONFIG_PATH=/opt/fstack-dpdk/lib/x86_64-linux-gnu/pkgconfig:/opt/fstack-dpdk/lib/pkgconfig
export LD_LIBRARY_PATH=/opt/fstack-dpdk/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH

make machine_includes
make -j$(nproc) 2>&1 | tail -10
LOG "F-Stack lib done: $(ls -lh libfstack.a 2>/dev/null)"

# Build F-Stack example echo server for benchmarking
cat > /tmp/ff_udp_echo.c << 'FFECHO'
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <ff_api.h>
#include <ff_epoll.h>

#define PORT 11114
#define BUF_SIZE 4096

static int epfd;
static int sock_fd;
static char buf[BUF_SIZE];

int loop(void *arg) {
    struct epoll_event events[64];
    int nev = ff_epoll_wait(epfd, events, 64, 0);
    for (int i = 0; i < nev; i++) {
        int fd = events[i].data.fd;
        if (events[i].events & EPOLLIN) {
            struct linux_sockaddr_storage from;
            socklen_t fl = sizeof(from);
            int n = ff_recvfrom(fd, buf, BUF_SIZE, 0,
                                (struct linux_sockaddr *)&from, &fl);
            if (n > 0) {
                ff_sendto(fd, buf, n, 0,
                          (struct linux_sockaddr *)&from, fl);
            }
        }
    }
    return 0;
}

int main(int argc, char *argv[]) {
    ff_init(argc, argv);
    sock_fd = ff_socket(AF_INET, SOCK_DGRAM, 0);
    struct linux_sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(PORT);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    ff_bind(sock_fd, (struct linux_sockaddr *)&addr, sizeof(addr));
    epfd = ff_epoll_create(1);
    struct epoll_event ev = {.events = EPOLLIN, .data.fd = sock_fd};
    ff_epoll_ctl(epfd, EPOLL_CTL_ADD, sock_fd, &ev);
    printf("F-Stack UDP echo on port %d\n", PORT);
    ff_run(loop, NULL);
    return 0;
}
FFECHO

gcc -O2 -o /usr/local/bin/ff_udp_echo /tmp/ff_udp_echo.c \
    -I/tmp/f-stack/lib/include \
    -L/tmp/f-stack/lib -lfstack \
    $(pkg-config --libs libdpdk) \
    -lnuma -lpthread -ldl -lm -lrt 2>&1 && \
    LOG "F-Stack echo server compiled" || LOG "F-Stack echo compile failed (lib OK)"

# ── 2. System DPDK 24.11 (for raw DPDK + AF_XDP) ───────────
LOG "=== Building system DPDK 24.11 with new libbpf ==="

# First: build libbpf 1.4.6 (required for DPDK AF_XDP PMD)
cd /tmp && rm -rf libbpf
git clone https://github.com/libbpf/libbpf --depth=1 -b v1.4.6 -q
cd libbpf/src
make -j$(nproc) > /dev/null 2>&1
make install PREFIX=/usr/local > /dev/null 2>&1
ldconfig
LOG "libbpf 1.4.6 installed: $(ldconfig -p | grep libbpf | head -1)"

# Build igb_uio
cd /tmp && rm -rf dpdk-kmods
git clone git://dpdk.org/dpdk-kmods --depth=1 -q
cd dpdk-kmods/linux/igb_uio
make -s CC=/usr/bin/gcc-12 2>&1 | grep -v "warning\|Skipping" | head -5
modprobe uio
rmmod igb_uio 2>/dev/null || true
insmod igb_uio.ko wc_activate=1 && LOG "igb_uio loaded with WC"

# Build DPDK 24.11 WITH new libbpf
cd /tmp && rm -rf dpdk
git clone https://dpdk.org/git/dpdk -b v24.11 --depth=1 -q
cd dpdk
export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/local/lib/x86_64-linux-gnu/pkgconfig:$PKG_CONFIG_PATH
meson setup build --buildtype=release \
  -Dexamples=l2fwd,l3fwd \
  -Ddisable_drivers='net/mlx4,net/mlx5,common/mlx5' \
  2>&1 | tail -5
ninja -C build -j$(nproc) 2>&1 | tail -5
ninja -C build install > /dev/null 2>&1
ldconfig
LOG "DPDK 24.11 installed: $(dpdk-testpmd -l 0 --no-pci -- --help 2>&1 | head -1)"

# ── 3. xdp-tools (for eBPF/XDP benchmarks) ─────────────────
LOG "=== Building xdp-tools ==="
apt-get install -y -qq m4 autoconf 2>&1 | tail -1
cd /tmp && rm -rf xdp-tools
git clone https://github.com/xdp-project/xdp-tools --depth=1 -q

# Patch the bool issue in kernel headers
sed -i '1s/^/#include <stdbool.h>\n/' xdp-tools/headers/linux/err.h

cd xdp-tools
sudo ./configure > /dev/null 2>&1 || ./configure > /dev/null 2>&1
make -j$(nproc) 2>&1 | tail -5
make install > /dev/null 2>&1 || true
XDB=$(find /tmp/xdp-tools -name 'xdp-bench' -type f 2>/dev/null | head -1)
[ -n "$XDB" ] && ln -sf "$XDB" /usr/local/bin/xdp-bench && LOG "xdp-bench: $XDB" || LOG "xdp-bench not built"

# Compile XDP_DROP program
cat > /tmp/xdp_drop.c << 'XDP'
#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>
SEC("xdp") int xdp_drop(struct xdp_md *ctx) { return XDP_DROP; }
char _license[] SEC("license") = "GPL";
XDP
clang -O2 -target bpf -I/usr/include -I/usr/include/x86_64-linux-gnu \
    -c /tmp/xdp_drop.c -o /tmp/xdp_drop.o && LOG "xdp_drop.o compiled" || LOG "xdp_drop compile failed"

# ── 4. liburing + io_uring echo server ─────────────────────
LOG "=== Building liburing + io_uring echo ==="
cd /tmp && rm -rf liburing io_uring_echo
git clone https://github.com/axboe/liburing --depth=1 -q
cd liburing && ./configure > /dev/null && make -j$(nproc) > /dev/null && make install > /dev/null && ldconfig
LOG "liburing installed"

# io_uring UDP echo (simple serial version that actually works)
cat > /tmp/iouring_echo.c << 'IOURC'
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <liburing.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#define RING_DEPTH 64
#define BUF_SIZE 4096
int main(int argc, char *argv[]) {
    const char *ip = argc > 1 ? argv[1] : "0.0.0.0";
    int port = argc > 2 ? atoi(argv[2]) : 11113;
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    int yes = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in a = {.sin_family=AF_INET, .sin_port=htons(port)};
    inet_pton(AF_INET, ip, &a.sin_addr);
    if (bind(fd,(struct sockaddr*)&a,sizeof(a))<0){perror("bind");return 1;}
    struct io_uring ring;
    io_uring_queue_init(RING_DEPTH, &ring, 0);
    printf("io_uring UDP echo on %s:%d\n", ip, port); fflush(stdout);
    char rbuf[BUF_SIZE], sbuf[BUF_SIZE];
    struct sockaddr_in peer; socklen_t peerlen;
    struct iovec riov={.iov_base=rbuf,.iov_len=BUF_SIZE};
    struct iovec siov={.iov_base=sbuf};
    struct msghdr rmsg={.msg_name=&peer,.msg_namelen=sizeof(peer),.msg_iov=&riov,.msg_iovlen=1};
    struct msghdr smsg={.msg_iov=&siov,.msg_iovlen=1};
    struct io_uring_cqe *cqe; struct io_uring_sqe *sqe;
    for(;;) {
        peerlen=sizeof(peer); rmsg.msg_namelen=peerlen; riov.iov_len=BUF_SIZE;
        sqe=io_uring_get_sqe(&ring); io_uring_prep_recvmsg(sqe,fd,&rmsg,0);
        sqe->user_data=1; io_uring_submit_and_wait(&ring,1);
        io_uring_wait_cqe(&ring,&cqe);
        int n=cqe->res; io_uring_cqe_seen(&ring,cqe);
        if(n<=0) continue;
        memcpy(sbuf,rbuf,n); siov.iov_len=n;
        smsg.msg_name=&peer; smsg.msg_namelen=sizeof(peer);
        sqe=io_uring_get_sqe(&ring); io_uring_prep_sendmsg(sqe,fd,&smsg,MSG_DONTWAIT);
        sqe->user_data=2; io_uring_submit_and_wait(&ring,1);
        io_uring_wait_cqe(&ring,&cqe); io_uring_cqe_seen(&ring,cqe);
    }
}
IOURC
gcc -O2 -o /usr/local/bin/iouring-udp-echo /tmp/iouring_echo.c -luring && LOG "io_uring echo compiled"

# ── 5. VPP with host-interface (af_packet) ─────────────────
LOG "=== Installing VPP ==="
curl -fsSL https://packagecloud.io/fdio/release/gpgkey 2>/dev/null | \
    gpg --dearmor -o /usr/share/keyrings/fdio.gpg
echo "deb [signed-by=/usr/share/keyrings/fdio.gpg] https://packagecloud.io/fdio/release/ubuntu jammy main" | \
    tee /etc/apt/sources.list.d/fdio.list > /dev/null
apt-get update -qq
apt-get install -y -qq vpp vpp-plugin-dpdk 2>&1 | tail -3
LOG "VPP: $(vpp --version 2>&1 | head -1)"

# VPP startup config (WITHOUT DPDK — use host-interface/af_packet)
cat > /etc/vpp/startup.conf << 'VPP'
unix {
  nodaemon
  log /tmp/vpp.log
  cli-listen /run/vpp/cli.sock
}
cpu { main-core 2 }
plugins {
  plugin dpdk_plugin.so { disable }
}
buffers { buffers-per-numa 32768 }
VPP
LOG "VPP configured"

# ── 6. Bind ens6 to igb_uio for DPDK tests ─────────────────
LOG "=== Binding ens6 to igb_uio ==="
# Get ens6 PCI address from sysfs (works regardless of driver)
if [ -L /sys/class/net/ens6/device ]; then
    PCI=$(basename $(readlink -f /sys/class/net/ens6/device))
    ip link set ens6 down
    dpdk-devbind.py --bind=igb_uio $PCI && LOG "ens6 ($PCI) bound to igb_uio"
else
    LOG "ens6 not found — will bind manually"
fi

LOG "=== Setup complete ==="
LOG "Summary:"
LOG "  F-Stack:    /tmp/f-stack/lib/libfstack.a ($(ls -lh /tmp/f-stack/lib/libfstack.a 2>/dev/null | awk '{print $5}'))"
LOG "  DPDK 24.11: $(dpdk-testpmd -l 0 --no-pci -- -h 2>&1 | head -1 || echo 'ok')"
LOG "  igb_uio:    $(lsmod | grep igb_uio | awk '{print $1, $3}')"
LOG "  io_uring:   $(ls /usr/local/bin/iouring-udp-echo 2>/dev/null)"
LOG "  VPP:        $(vpp --version 2>&1 | head -1)"
