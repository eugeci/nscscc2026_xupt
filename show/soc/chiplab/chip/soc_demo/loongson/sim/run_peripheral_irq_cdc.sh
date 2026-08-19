#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHIPLAB_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
CORE_DIR="$(cd "$CHIPLAB_DIR/../core" && pwd)"
VCS_SHIM="$CORE_DIR/02_Design/verification/tools/vcs_pthread_yield.c"
WORK_DIR="$(mktemp -d /tmp/peripheral_irq_cdc.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

vcs -full64 -sverilog -timescale=1ns/1ps \
    -top tb_peripheral_irq_cdc \
    +incdir+"$CHIPLAB_DIR/chip/soc_demo/loongson" \
    -Mdir="$WORK_DIR/csrc" \
    -o "$WORK_DIR/simv" \
    "$CHIPLAB_DIR/chip/soc_demo/loongson/soc_top.v" \
    "$SCRIPT_DIR/tb_peripheral_irq_cdc.sv" \
    "$VCS_SHIM"

LOG_FILE="$WORK_DIR/run.log"
if ! "$WORK_DIR/simv" >"$LOG_FILE" 2>&1; then
    sed -n '1,240p' "$LOG_FILE"
    exit 1
fi
sed -n '1,240p' "$LOG_FILE"

# Older VCS versions may return zero after SystemVerilog $fatal, so require an
# explicit pass marker and independently reject fatal output.
if grep -Eq '\[FAIL\]|Fatal:' "$LOG_FILE"; then
    echo "[FAIL] VCS reported a fatal error in peripheral IRQ CDC test" >&2
    exit 1
fi
if ! grep -Fq '[PASS] peripheral IRQ CDC preserves levels and short pulses' "$LOG_FILE"; then
    echo "[FAIL] VCS did not emit the peripheral IRQ CDC pass marker" >&2
    exit 1
fi
