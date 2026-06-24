//! Minimal reproducer: intermittent ESP32-C6 panic during WiFi+ESP-NOW+BLE
//! coexistence bring-up at boot.
//!
//! On ~a few percent of (JTAG-reset) boots this panics with a caught CPU
//! exception (esp-hal `exception_handler`) or an init-path failure, somewhere
//! in the radio/clock/flash bring-up — most often inside
//! `esp_radio::ble::controller::BleConnector::new`, but it relocates to
//! `esp_radio::wifi::new`, the esp-hal clock config, or the watchdog setup on
//! other boots. A reset clears it; most boots are clean.
//!
//! Reproduce with the accompanying `reset-loop.sh` (drives `probe-rs reset` +
//! RTT capture in a loop and tallies panics). See README.md.

#![no_std]
#![no_main]

extern crate alloc;

use esp_backtrace as _;
use defmt_rtt as _;
use defmt::info;
use esp_hal::clock::CpuClock;
use esp_hal::timer::timg::TimerGroup;
use esp_hal::interrupt::software::SoftwareInterruptControl;
use esp_radio::ble::controller::BleConnector;
use esp_radio::wifi::{self, Config as WifiConfig};

esp_bootloader_esp_idf::esp_app_desc!();

// defmt timestamp: microseconds since boot, from the embassy-time clock that
// esp-rtos installs. (Reads 0 for the very first lines before esp_rtos::start
// brings the time driver up — harmless.) Silences the probe-rs warning:
// "logger format contains timestamp but no timestamp implementation".
defmt::timestamp!("{=u64:us}", embassy_time::Instant::now().as_micros());

// --- Which pre-radio step(s) to include before esp-radio bring-up (issue #485) ---
// Bisect result (150 JTAG-reset boots each):
//   bare (all false) ............ 0/150  clean
//   flash read only ............. 0/150  clean
//   CPU_WAITI_CONF poke only .... 2/150  (~1.3%)  REPRODUCES
//   TIMG1 watchdog only ......... 6/150  (~4%)    REPRODUCES (strongest)
// The trigger is a pre-radio write to CLOCK/PMU/TIMER register state (watchdog
// or PCR); a flash-only read (no clock/PMU touch) does NOT trigger it.
// Default below = the minimal single trigger (watchdog only).
const ENABLE_WAITI_POKE: bool = false; // PCR.CPU_WAITI_CONF bit 3 (also triggers, ~1.3%)
const ENABLE_WDT: bool = true; // TIMG1 MWDT enable before radio (trigger, ~4%)
const ENABLE_FLASH_READ: bool = false; // flash partition-table read (does NOT trigger)

#[esp_rtos::main]
async fn main(_spawner: embassy_executor::Spawner) -> ! {
    // 1. esp-hal init (clock config — one of the intermittent fault sites).
    let config = esp_hal::Config::default().with_cpu_clock(CpuClock::max());
    let mut peripherals = esp_hal::init(config);
    info!("[1] esp_hal::init OK");

    // 1b. C6 PCR.CPU_WAITI_CONF bit 3: keep CPU clock running during WFI (so
    // probe-rs can read RTT). Mirrors the firmware that exhibited the bug.
    if ENABLE_WAITI_POKE {
        unsafe {
            let reg = 0x6009_6114 as *mut u32; // PCR.CPU_WAITI_CONF
            core::ptr::write_volatile(reg, core::ptr::read_volatile(reg) | (1 << 3));
        }
        info!("[1b] CPU_WAITI_CONF poke OK");
    }

    // 2. esp-rtos scheduler (timer + software interrupt 0).
    let timg0 = TimerGroup::new(peripherals.TIMG0);
    let sw_int = SoftwareInterruptControl::new(peripherals.SW_INTERRUPT);
    esp_rtos::start(timg0.timer0, sw_int.software_interrupt0);
    info!("[2] esp_rtos::start OK");

    // 2b. TIMG1 MWDT watchdog enabled BEFORE radio (Wdt::set_wdt_enabled was
    // itself an observed fault site). 15s, matches the firmware.
    if ENABLE_WDT {
        let timg1 = TimerGroup::new(peripherals.TIMG1);
        let mut wdt = timg1.wdt;
        wdt.set_timeout(
            esp_hal::timer::timg::MwdtStage::Stage0,
            esp_hal::time::Duration::from_secs(15),
        );
        wdt.enable();
        core::mem::forget(wdt); // keep it alive without a static
        info!("[2b] WDT enabled OK");
    }

    // 3. Heap (esp-radio needs an allocator). 96 KiB matches our firmware.
    esp_alloc::heap_allocator!(size: 96 * 1024);
    info!("[3] heap OK");

    // 3b. Flash read BEFORE radio (mirrors the firmware's Esp32Nvs::new, which
    // reads the partition table — an observed fault site, "Form B"). esp-storage
    // disables the flash cache during the SPI read; doing this in the pre-radio
    // window matches the firmware exactly.
    if ENABLE_FLASH_READ {
        use esp_storage::FlashStorage;
        let mut flash = FlashStorage::new(peripherals.FLASH.reborrow());
        let mut pt_mem = [0u8; esp_bootloader_esp_idf::partitions::PARTITION_TABLE_MAX_LEN];
        let _ = esp_bootloader_esp_idf::partitions::read_partition_table(&mut flash, &mut pt_mem);
        info!("[3b] flash partition-table read OK");
    }

    // 4. WiFi controller + ESP-NOW interface (another intermittent fault site).
    let (mut wifi_controller, interfaces) =
        wifi::new(peripherals.WIFI, Default::default()).expect("wifi::new failed");
    wifi_controller
        .set_config(&WifiConfig::Station(wifi::sta::StationConfig::default()))
        .expect("wifi set_config failed");
    info!("[4] wifi::new + Station config OK");

    // ESP-NOW driver in STA mode, set a fixed channel (mirrors our boot path).
    let esp_now = interfaces.esp_now;
    esp_now.set_channel(1).expect("esp_now set_channel failed");
    info!("[5] esp-now + set_channel OK");

    // 5. TRNG seed (mirrors our BLE-seed step that reborrows RNG/ADC1).
    let _seed: [u8; 32] = {
        use esp_hal::rng::{Trng, TrngSource};
        let _src = TrngSource::new(peripherals.RNG.reborrow(), peripherals.ADC1.reborrow());
        let trng = Trng::try_new().expect("TRNG bring-up");
        let mut s = [0u8; 32];
        trng.read(&mut s);
        s
    };
    info!("[6] TRNG seed OK");

    // 6. BLE controller bring-up under active WiFi+ESP-NOW coex.
    //    *** This is the most frequent intermittent fault site. ***
    //    Default BLE config — the fault reproduces with default config too
    //    (verified by ablation), so no custom buffer tuning is needed here.
    let ble_config = esp_radio::ble::Config::default();
    let ble_connector =
        BleConnector::new(peripherals.BT, ble_config).expect("BleConnector::new failed");
    let _ble_controller = bt_hci::controller::ExternalController::<_, 20>::new(ble_connector);
    info!("[7] BleConnector::new + ExternalController OK -- COEX BRING-UP COMPLETE");

    // Idle forever. A clean boot reaches here; a faulting boot panics above
    // (the panic line + backtrace is emitted by esp-backtrace).
    let mut n: u32 = 0;
    loop {
        embassy_time::Timer::after(embassy_time::Duration::from_secs(10)).await;
        n += 1;
        info!("[idle] alive {}", n);
    }
}
