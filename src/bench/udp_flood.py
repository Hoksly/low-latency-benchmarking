#!/usr/bin/env python3
"""UDP packet generator (traffic source) for throughput scenarios.

Sends fixed-size UDP packets to a target as fast as a single thread can for a
fixed duration, then reports the achieved send rate. Run on the GEN instance
against the SUT for scenarios S4 (eBPF/XDP_DROP) and as a software generator
where a DPDK generator is not used.

Usage:
    python3 udp_flood.py <host> <port> [--seconds S] [--size BYTES]

Example (S4 XDP_DROP flood, 60-byte frames, 30 s):
    python3 udp_flood.py 172.31.5.23 9999 --seconds 30 --size 60
"""
import argparse
import socket
import time


def flood(host: str, port: int, seconds: int, size: int):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)
    pkt = b"A" * size
    addr = (host, port)
    sent = 0
    end = time.time() + seconds
    while time.time() < end:
        try:
            s.sendto(pkt, addr)
            sent += 1
        except OSError:
            pass  # ENOBUFS under pressure — keep going
    return sent


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("host")
    ap.add_argument("port", type=int)
    ap.add_argument("--seconds", type=int, default=30)
    ap.add_argument("--size", type=int, default=60)
    a = ap.parse_args()
    sent = flood(a.host, a.port, a.seconds, a.size)
    print(f"sent {sent} packets in {a.seconds}s = {sent // a.seconds} pps "
          f"(payload {a.size} B)")


if __name__ == "__main__":
    main()
