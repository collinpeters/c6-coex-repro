# Minimal reproducer — intermittent ESP32-C6 panic during WiFi+ESP-NOW+BLE coex bring-up

A self-contained `no_std` ESP32-C6 binary that intermittently panics during the
radio coexistence bring-up at boot. ~140 lines, no application code.

## Symptom

On a few percent of boots (after a reset), the firmware panics with a **caught
CPU exception** (`esp-hal exception_handler`) or an init-path `Result` failure,
somewhere in the radio / clock / flash bring-up. Most boots are clean and reach
`[7] ... COEX BRING-UP COMPLETE`. A reset clears it.

The faulting site **moves between boots** — observed in the original (larger)
firmware and this reproducer:

- `esp_radio::ble::controller::BleConnector::new` (most frequent)
- `esp_radio::wifi::new`
- `esp_hal::init` clock config (`request_soc_root_clk` → unwrap of `None`)
- `esp_hal::timer::timg::Wdt::set_wdt_enabled`
- a `fugit::Rate` div-by-zero (clock rate read back as 0)

Because the fault relocates across independent init steps, it looks like a
shared init-timing / silicon issue rather than a single-call bug. It is **not**
fixed on esp-rs `main` (tested up to `c2823973`).

## Versions

esp-hal 1.1.1, esp-radio 0.18.0, esp-rtos 0.3.0, esp-alloc 0.10.0,
esp-bootloader-esp-idf 0.5.0, esp-backtrace 0.19.0, bt-hci 0.8.1.
Toolchain: esp / nightly (riscv32imac-unknown-none-elf). Target: ESP32-C6.

## Build

```
cargo build --release            # esp toolchain, target from .cargo/config.toml
```

## Reproduce

Single run (clean boot reaches step [7]):

```
probe-rs run --chip esp32c6 target/riscv32imac-unknown-none-elf/release/c6-coex-repro
# or: probe-rs attach --chip esp32c6 --rtt-scan-memory <elf>
```

Loop to surface the intermittent panic (it is ~1.3% per boot, so you
need a few dozen boots):

```
./reset-loop.sh <PROBE_SERIAL> 150     # PROBE_SERIAL from `probe-rs list`
```

It tallies panics vs clean boots and saves each boot's RTT to `repro-logs/`.
Decode a panic backtrace with `riscv64-unknown-elf-addr2line` / `addr2line`
against the release ELF.

## What triggers it (bisect, 150 JTAG-reset boots per variant, board 8C:FD:49:18:49:00)

The bare coex bring-up does NOT fault. The fault appears only when a **clock /
PMU / timer register is written before esp-radio bring-up**:

| pre-radio step                        | panics / 150 | reproduces? |
|---------------------------------------|--------------|-------------|
| none (bare coex)                      | 0            | no          |
| flash partition-table read only       | 0            | no          |
| `PCR.CPU_WAITI_CONF` poke only        | 2  (~1.3%)   | **yes**     |
| **TIMG1 watchdog enable only**        | **6 (~4%)**  | **yes** (strongest) |

Toggle the three `ENABLE_*` consts at the top of `src/main.rs` to reproduce each
row. The default ships **watchdog-only** (minimal single trigger). The
flash-only read — which touches the SPI-flash controller but no clock/PMU state —
stays clean, so the trigger is specifically the clock/PMU/timer write.

## The fault

A caught CPU exception or a NimBLE controller-init assert, during the radio
bring-up that follows the trigger. Per-step `info!` markers show exactly which
call faulted (it never logs the line after the faulting step). Observed:

- `esp_radio::ble::controller::BleConnector::new` →
  - `esp-radio-0.18.0/src/ble/npl.rs:1167`: `assert!(res == 0, "ble_controller_init returned {}", res)` (`r_ble_controller_init` returns nonzero), or
  - `npl.rs:1240`: `assert!(res == 0, "ble_controller_enable returned {}", res)`, or
  - a caught CPU exception (`esp-hal exception_handler/mod.rs:112`) on the same path.
- It also relocates to `esp_radio::wifi::new` on some boots.

## Notes

- All reproduction used **JTAG resets** (`probe-rs reset`). Rate on a clean power
  cycle is untested.
- Default `esp_radio::ble::Config` — not dependent on any custom buffer/coex
  tuning.
- Not fixed on esp-rs `main` (tested up to commit `c2823973`).
