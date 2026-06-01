#!/usr/bin/env python3
"""UDP round-trip latency measurement against an echo server.

Sends N fixed-size UDP packets one at a time, waits for the echo, and records
the round-trip time. Reports avg / std-dev / P50 / P99 / P99.9 one-way latency
(RTT divided by two). Used for scenarios S3 (io_uring), S5 (AF_XDP), S6 (DPDK
mac-swap), S8 (F-Stack), S9 (Seastar).

Usage:
    python3 rtt_latency.py <host> <port> [--count N] [--size BYTES] [--warmup W]

Example:
    python3 rtt_latency.py 172.31.5.23 11113 --count 10000 --size 64
"""
import argparse
import socket
import statistics
import time


def measure(host: str, port: int, count: int, size: int, warmup: int, timeout: float):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    pkt = b"A" * size

    for _ in range(warmup):
        s.sendto(pkt, (host, port))
        try:
            s.recvfrom(size + 64)
        except socket.timeout:
            pass

    rtts, lost = [], 0
    for _ in range(count):
        t0 = time.perf_counter()
        s.sendto(pkt, (host, port))
        try:
            s.recvfrom(size + 64)
            rtts.append((time.perf_counter() - t0) * 1e6)  # microseconds
        except socket.timeout:
            lost += 1
    return rtts, lost


def report(rtts, lost, size):
    if not rtts:
        print("no replies received — is the echo server running?")
        return
    rtts.sort()
    n = len(rtts)
    half = [r / 2 for r in rtts]  # one-way ≈ RTT / 2
    print(f"UDP echo latency  (payload {size} B, N={n + lost})")
    print(f"  avg one-way = {statistics.mean(half):.3f} us")
    print(f"  std-dev     = {statistics.stdev(half):.3f} us" if n > 1 else "")
    print(f"  P50         = {half[n // 2]:.3f} us")
    print(f"  P99         = {half[int(0.99 * n)]:.3f} us")
    print(f"  P99.9       = {half[min(int(0.999 * n), n - 1)]:.3f} us")
    print(f"  lost        = {lost}/{n + lost}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("host")
    ap.add_argument("port", type=int)
    ap.add_argument("--count", type=int, default=10000)
    ap.add_argument("--size", type=int, default=64)
    ap.add_argument("--warmup", type=int, default=200)
    ap.add_argument("--timeout", type=float, default=1.0)
    a = ap.parse_args()
    rtts, lost = measure(a.host, a.port, a.count, a.size, a.warmup, a.timeout)
    report(rtts, lost, a.size)


if __name__ == "__main__":
    main()
