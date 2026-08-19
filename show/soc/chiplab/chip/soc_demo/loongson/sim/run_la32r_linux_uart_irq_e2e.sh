#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHIPLAB_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
CORE_DIR="$(cd "$CHIPLAB_DIR/../core" && pwd)"
CORE_PLATFORM_DIR="$CORE_DIR/02_Design/platform/nscscc"
UART_DIR="$CHIPLAB_DIR/IP/APB_DEV/URT"
VCS_SHIM="$CORE_DIR/02_Design/verification/tools/vcs_pthread_yield.c"
WORK_DIR="$(mktemp -d /tmp/la32r_uart_irq_e2e.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT
EXPECT_FIRST_BYTE_LOSS="${EXPECT_FIRST_BYTE_LOSS:-0}"

(
    cd "$CORE_PLATFORM_DIR"
    vcs -full64 -sverilog -timescale=1ns/1ps \
        -top tb_la32r_linux_uart_irq_e2e \
        +incdir+"$CHIPLAB_DIR/chip/soc_demo/loongson" \
        +incdir+"$UART_DIR" \
        -Mdir="$WORK_DIR/csrc" \
        -o "$WORK_DIR/simv" \
        -F filelist.f \
        "$CHIPLAB_DIR/IP/AMBA/axi2apb.v" \
        "$CHIPLAB_DIR/IP/APB_DEV/apb_mux2.v" \
        "$UART_DIR/uart_top.v" \
        "$UART_DIR/uart_regs.v" \
        "$UART_DIR/uart_tfifo.v" \
        "$UART_DIR/uart_receiver.v" \
        "$UART_DIR/uart_transmitter.v" \
        "$UART_DIR/uart_rfifo.v" \
        "$UART_DIR/uart_sync_flops.v" \
        "$UART_DIR/raminfr.v" \
        "$CHIPLAB_DIR/IP/APB_DEV/apb_dev_top_no_nand.v" \
        "$SCRIPT_DIR/tb_la32r_linux_uart_irq_e2e.sv" \
        "$VCS_SHIM"
)

run_case() {
    local phase="$1"
    local fcr="$2"
    local expected_iir="$3"
    local log_file="$WORK_DIR/run_fcr${fcr}_phase${phase}.log"
    local -a extra_args=()
    local expected_marker="[PASS] LA32R Linux UART IRQ end-to-end replay"

    if [[ "$EXPECT_FIRST_BYTE_LOSS" == "1" ]]; then
        extra_args+=(+EXPECT_FIRST_BYTE_LOSS)
        expected_marker="[OBSERVED] UART_FIRST_BYTE_LOSS_BY_IIR"
        if [[ "$phase" == "0" ]]; then
            extra_args+=(+TRACE_UART)
        fi
    fi

    if ! (cd "$WORK_DIR" && ./simv \
        +UNCORE_HALF_NS=7 +UNCORE_PHASE_NS="$phase" \
        +RX_START_DELAY="$phase" \
        +UART_FCR="$fcr" +EXPECTED_IIR="$expected_iir" \
        "${extra_args[@]}") >"$log_file" 2>&1; then
        sed -n '1,240p' "$log_file"
        return 1
    fi
    sed -n '1,240p' "$log_file"

    # Older VCS versions return zero even after SystemVerilog $fatal. Require
    # an explicit success/diagnostic marker and reject fatal text ourselves.
    if grep -Eq '\[FAIL\]|Fatal:' "$log_file"; then
        echo "[FAIL] VCS reported a fatal error for fcr=$fcr phase=$phase" >&2
        return 1
    fi
    if ! grep -Fq "$expected_marker" "$log_file"; then
        echo "[FAIL] VCS did not emit expected marker: $expected_marker" >&2
        return 1
    fi
}

# The board report used the Linux trigger-one setup. Sweep non-harmonic
# CPU/uncore phases to prove the first-byte result is not a CDC phase effect.
for phase in 0 1 3 6; do
    run_case "$phase" 01 c4
done

if [[ "$EXPECT_FIRST_BYTE_LOSS" == "1" ]]; then
    echo "[PASS] current RTL deterministically reproduces UART first-byte loss"
else
    # Keep receiver-timeout coverage in the strict post-fix regression.
    for phase in 0 2 5; do
        run_case "$phase" 81 cc
    done
    echo "[PASS] LA32R Linux UART IRQ end-to-end phase/trigger matrix"
fi
