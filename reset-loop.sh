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

PANIC=0; CLEAN=0; HANG=0; NOOUT=0; BUSY=0
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
  elif grep -qE '\[[0-9b]+\]' "$CAP"; then
    # Reached a boot step but never completed or panicked within the window =
    # a silent HANG (e.g. wifi::new / BleConnector::new never returns; the
    # device's own 15s watchdog would eventually reset it). Report last step.
    # Checked BEFORE the probe-busy branch: real firmware output (the [N]
    # markers) is unambiguous and wins, even if a probe shutdown-warning
    # (`Stall`/`ConnectionReset`) also appears in the same capture.
    HANG=$((HANG+1))
    LAST=$(grep -oE '\[[0-9b]+\]' "$CAP" | tail -1)
    echo "iter $i: HANG — stalled after step $LAST (no completion, no panic)"
  elif grep -qiE "could not (open|connect)|probe.*(in use|busy)|interface is busy|No such device|Access denied|Arbitration|the requested resource is in use|failed to (open|attach)|debug probe could not be created" "$CAP"; then
    # No firmware output at all, AND a probe/USB error → another probe-rs has
    # the JTAG interface (or it's wedged). Note: `Stall`/`ConnectionReset`
    # alone were dropped from this pattern — they also occur in normal attach
    # teardown, so they are NOT reliable busy indicators on their own.
    BUSY=$((BUSY+1))
    echo "iter $i: PROBE BUSY — is another probe-rs attached? ($(grep -m1 -iE 'busy|could not|access denied|no such device' "$CAP" | tr -d '\r' | head -c 70))"
  else
    NOOUT=$((NOOUT+1))
    echo "iter $i: no output (no RTT captured — board reset slow, or probe issue)"
  fi
done

echo "=== $ITERS iters | panics=$PANIC clean=$CLEAN hangs=$HANG probe-busy=$BUSY no-output=$NOOUT ==="
echo "Full per-iteration capture: $RUNLOG"
