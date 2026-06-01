#!/bin/bash
# ============================================================
# run.sh — single entry point for the full experiment
#
# Usage:
#   bash run.sh [KEY_PATH]
#
# KEY_PATH defaults to ~/.ssh/diploma-bench-key.pem
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

KEY_PATH="${1:-$HOME/.ssh/diploma-bench-key.pem}"

# ── Step 1: Provision / verify testbed ───────────────────────
echo
echo "══════════════════════════════════════════════════════"
echo "  Step 1/3 — Provisioning testbed"
echo "══════════════════════════════════════════════════════"
bash "$SCRIPT_DIR/src/infra/aws_launch.sh" "$KEY_PATH"

source /tmp/bench-ips.env   # provides SUT_PUB, GEN_PUB, KEY_PATH

# ── Steps 2 + 3: Install dependencies and run benchmarks ─────
echo
echo "══════════════════════════════════════════════════════"
echo "  Step 2/3 — Installing dependencies"
echo "  Step 3/3 — Benchmarks"
echo "══════════════════════════════════════════════════════"
bash "$SCRIPT_DIR/src/infra/run_full_experiment.sh" \
    "$SUT_PUB" "$GEN_PUB" "$KEY_PATH"
