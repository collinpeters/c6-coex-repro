#!/usr/bin/env bash
# Reproduce the intermittent ESP32-C6 coex-bring-up panic.
# Resets the board over JTAG and captures the boot via RTT, looping N times,
# tallying boots that panic vs reach "COEX BRING-UP COMPLETE".
#
# Usage: ./reset-loop.sh [PROBE_SERIAL] [ITERS]
#   PROBE_SERIAL e.g. 303a:1001:8C:FD:49:18:49:00 (from `probe-rs list`)
set -u
PROBE="${1:-303a:1001:8C:FD:49:18:49:00}"
ITERS="${2:-100}"
CHIP="esp32c6"
ELF="$(dirname "$0")/target/riscv32imac-unknown-none-elf/release/c6-coex-repro"
LOGDIR="$(dirname "$0")/repro-logs"
mkdir -p "$LOGDIR"
PANIC=0; CLEAN=0; NOOUT=0

for i in $(seq 1 "$ITERS"); do
  LOG="$LOGDIR/iter_$(printf '%03d' "$i").log"
  probe-rs reset --chip "$CHIP" --probe "$PROBE" >/dev/null 2>&1
  timeout 8 probe-rs attach --chip "$CHIP" --probe "$PROBE" --rtt-scan-memory \
    --log-format "{t} [{L}] {s} ({f}:{l})" "$ELF" >"$LOG" 2>&1
  if grep -qiE "panic|exception_handler|EXCEPTION|access fault|IllegalInstruction" "$LOG"; then
    PANIC=$((PANIC+1))
    echo "iter $i: *** PANIC *** $(grep -m1 -iE 'panicked at|expect' "$LOG" | tr -d '\r' | sed 's#/home/[^ ]*/##')"
  elif grep -q "COEX BRING-UP COMPLETE" "$LOG"; then
    CLEAN=$((CLEAN+1))
  else
    NOOUT=$((NOOUT+1)); echo "iter $i: no output"
  fi
done
echo "=== $ITERS iters | panics=$PANIC clean=$CLEAN no-output=$NOOUT ==="
