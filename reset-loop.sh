#!/usr/bin/env bash
# Reproduce the intermittent ESP32-C6 coex-bring-up panic.
# Resets the board over JTAG and captures the boot via RTT, looping N times,
# tallying boots that panic vs reach "COEX BRING-UP COMPLETE".
#
# Usage: ./reset-loop.sh [PROBE_SERIAL] [ITERS] [CAP_SECS]
#   PROBE_SERIAL  e.g. 303a:1001:8C:FD:49:18:49:00 (from `probe-rs list`)
#   ITERS         number of reset/boot iterations (default 100)
#   CAP_SECS      per-boot RTT capture window in seconds (default 2)
#
# All iterations are written to a single timestamped log under repro-logs/,
# separated by a header line per iteration. The console shows one line per
# iteration (clean / PANIC / probe-busy / no-output) plus a final summary.
#
# NOTE: only ONE process can use the JTAG probe at a time. If another
# `probe-rs` is attached, every iteration reports "PROBE BUSY".
set -u
PROBE="${1:-303a:1001:8C:FD:49:18:49:00}"
ITERS="${2:-100}"
# Per-boot RTT capture window (seconds). The firmware idles forever after
# "COEX BRING-UP COMPLETE", so `probe-rs attach` never exits on its own and this
# timeout bounds each iteration — it IS the per-iteration cost. The full boot
# (init → COEX complete, and any panic) lands within ~0.4s, so 2s is ample and
# keeps iterations short. Raise it only if your board boots slower.
CAP_SECS="${3:-2}"
CHIP="esp32c6"
ELF="$(dirname "$0")/target/riscv32imac-unknown-none-elf/release/c6-coex-repro"
LOGDIR="$(dirname "$0")/repro-logs"
mkdir -p "$LOGDIR"

if [ ! -f "$ELF" ]; then
  echo "ERROR: firmware not built: $ELF"
  echo "Run: cargo build --release"
  exit 1
fi

# Single timestamped log file for the whole run.
RUNLOG="$LOGDIR/run-$(date +%Y%m%d-%H%M%S).log"
echo "Run log: $RUNLOG"

PANIC=0; CLEAN=0; NOOUT=0; BUSY=0
CAP="$(mktemp)"
trap 'rm -f "$CAP"' EXIT

for i in $(seq 1 "$ITERS"); do
  probe-rs reset --chip "$CHIP" --probe "$PROBE" >/dev/null 2>&1
  timeout "$CAP_SECS" probe-rs attach --chip "$CHIP" --probe "$PROBE" --rtt-scan-memory \
    --log-format "{t} [{L}] {s} ({f}:{l})" "$ELF" >"$CAP" 2>&1

  # Append this iteration's capture to the single run log, with a separator.
  {
    printf '========== iter %03d ==========\n' "$i"
    cat "$CAP"
    printf '\n'
  } >> "$RUNLOG"

  if grep -qiE "panic|exception_handler|EXCEPTION|access fault|IllegalInstruction" "$CAP"; then
    PANIC=$((PANIC+1))
    echo "iter $i: *** PANIC *** $(grep -m1 -iE 'panicked at|expect' "$CAP" | tr -d '\r' | sed 's#/home/[^ ]*/##')"
  elif grep -q "COEX BRING-UP COMPLETE" "$CAP"; then
    CLEAN=$((CLEAN+1))
    echo "iter $i: clean"
  elif grep -qiE "could not (open|connect)|probe.*(in use|busy)|Connection.*(Reset|refused)|No such device|Access denied|Stall|Arbitration|the requested resource is in use|failed to (open|attach)" "$CAP"; then
    BUSY=$((BUSY+1))
    echo "iter $i: PROBE BUSY — is another probe-rs attached? ($(grep -m1 -iE 'error|in use|busy|stall' "$CAP" | tr -d '\r' | head -c 70))"
  else
    NOOUT=$((NOOUT+1))
    echo "iter $i: no output (board produced no RTT in the capture window)"
  fi
done

echo "=== $ITERS iters | panics=$PANIC clean=$CLEAN probe-busy=$BUSY no-output=$NOOUT ==="
echo "Full per-iteration capture: $RUNLOG"
