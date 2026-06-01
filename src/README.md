# Source code — Low-Latency Networking thesis

All code used to produce the thesis: the Chapter 3 benchmark experiments (AWS
cloud) and the document build tooling (PDF + DOCX). Organized so each piece is
a small, standalone, editable file.

## Layout

```
src/
├── infra/
│   └── aws_launch.sh        # launch the 2x c6in.xlarge testbed (reference commands)
├── setup/
│   ├── setup_all.sh         # install everything on a host: F-Stack+DPDK, libbpf,
│   │                        #   xdp-tools, liburing, VPP, igb_uio (run with: sudo bash)
│   └── setup_seastar.sh     # Seastar build (separate: ~20-30 min, run after setup_all)
├── servers/                 # the UDP echo servers, one per technology
│   ├── iouring_echo.c       # S3: io_uring (liburing), serial recvmsg+sendmsg
│   ├── ff_udp_echo.c        # S8: F-Stack (FreeBSD stack on DPDK), epoll
│   └── seastar_echo.cc      # S9: Seastar reactor / shard-per-core
├── programs/
│   └── xdp_drop.c           # S4: eBPF XDP_DROP program (clang -> BPF object)
├── config/
│   ├── vpp_startup.conf     # S7: VPP, DPDK plugin disabled (host-interface mode)
│   ├── vcl.conf             # S7: VPP comms library config
│   └── f-stack.conf         # S8: F-Stack DPDK lcore/port config
├── bench/
│   ├── run_all.sh           # orchestrates scenarios S1..S9 on the SUT
│   ├── rtt_latency.py       # one-way UDP latency vs an echo server (S3,S5,S6,S8,S9)
│   └── udp_flood.py         # UDP traffic generator (S4 flood, software generator)
└── thesis/
    ├── build_pdf.sh         # XeLaTeX -> CourseWork.pdf (3 passes for the TOC)
    └── build_docx.py        # pandoc + fixups -> CourseWork.docx (styled, TOC, page nums)
```

The thesis source `CourseWork.tex` lives at the **project root** (one level up),
not in here, so there is a single live copy. The `thesis/` scripts build it.

## The nine scenarios (Chapter 3)

| ID | Technology        | Code / config                         | Metric    |
|----|-------------------|---------------------------------------|-----------|
| S1 | Kernel baseline   | stock sockets (sockperf / iperf3)     | lat + pps |
| S2 | Tuned kernel      | CPU pin, coalescing off, busy-poll    | lat + pps |
| S3 | io_uring          | `servers/iouring_echo.c`              | latency   |
| S4 | eBPF/XDP_DROP     | `programs/xdp_drop.c` + `udp_flood.py`| pps       |
| S5 | AF_XDP (DPDK PMD) | DPDK `net_af_xdp` + `rtt_latency.py`  | lat + pps |
| S6 | DPDK testpmd      | testpmd mac-swap/txonly/rxonly        | lat + pps |
| S7 | VPP               | `config/vpp_startup.conf`, `vcl.conf` | latency   |
| S8 | F-Stack           | `servers/ff_udp_echo.c`, `f-stack.conf`| latency  |
| S9 | Seastar           | `servers/seastar_echo.cc`             | lat + pps |

## How to reproduce the benchmarks

```bash
# 1. launch the testbed (edit IDs first)
bash src/infra/aws_launch.sh

# 2. on EACH host: install the stack
scp -r src ubuntu@<host>:/tmp/
ssh ubuntu@<host> "sudo bash /tmp/src/setup/setup_all.sh"
ssh ubuntu@<host> "sudo bash /tmp/src/setup/setup_seastar.sh"   # optional, slow

# 3. on the SUT: run all scenarios (the GEN host sends traffic when prompted)
ssh ubuntu@<SUT> "bash /tmp/src/bench/run_all.sh"
```

`run_all.sh` writes per-scenario results to `/tmp/results/` on the SUT.

### Measuring latency / throughput by hand

```bash
# latency against an echo server (one-way, RTT/2)
python3 src/bench/rtt_latency.py 172.31.5.23 11113 --count 10000 --size 64

# throughput flood (run on GEN, points at SUT)
python3 src/bench/udp_flood.py 172.31.5.23 9999 --seconds 30 --size 60
```

## How to build the documents

```bash
# PDF (needs xelatex; texlive-xetex + texlive-latex-extra)
bash src/thesis/build_pdf.sh

# DOCX (needs pandoc, python-docx, libreoffice, poppler-utils)
python3 src/thesis/build_docx.py
```

The PDF table of contents is **live** (regenerates each build). The DOCX TOC is
a **static snapshot** of page numbers — re-run `build_docx.py` after editing
content so the numbers stay correct.

## Key environment facts (so results reproduce)

- Instances: AWS c6in.xlarge (Intel Xeon Platinum 8375C, 4 vCPU), cluster
  placement group, eu-central-1c, Ubuntu 22.04, kernel 6.8.0-1055-aws.
- ENA has **no hardware timestamping** → latency uses TSC software timestamps.
- ENA is **not** in the AF_XDP zero-copy driver list → S5 runs in copy mode.
- IOMMU is not exposed to non-bare-metal Nitro guests → DPDK uses `igb_uio`
  (with `wc_activate=1`), not `vfio-pci`.
- libbpf 1.4.6 must be built from source and the system `libbpf-dev` 0.5.0
  removed first, or the libxdp / DPDK AF_XDP builds fail (see `setup_all.sh`).
- ens6 needs `ethtool -L ens6 combined 2` before XDP attaches on ENA (S4).
- Source/dest check must be disabled on both benchmark ENIs for reply routing.
```
