# NVMe AER Error Monitor

A live, colorized monitor for PCIe Advanced Error Reporting (AER) on NVMe
controllers. It polls each controller's AER capability registers, decodes
the correctable and uncorrectable status bits into human-readable error
names, and tracks per-device event totals along with a rolling log of
recent error events.

The live view draws on the terminal's **alternate screen** (like `htop` or
`less`): your scrollback history is untouched while it runs and is restored
when you quit, at which point a session summary is printed so you keep a
record of what was observed.

## Features

- Full-screen live view with in-place, flicker-free updates — never clears
  your terminal history
- Monitors **both** AER status registers: correctable (offset `+0x10`) and
  uncorrectable (offset `+0x04`)
- Decodes latched status bits into names matching kernel AER output
  (`RxErr`, `BadTLP`, `BadDLLP`, `AdvNF`, `CmpltTO`, `MalfTLP`, ...)
- Per-device health dot, serial, model, and current PCIe link speed/width,
  with a warning when a link trains below the drive's maximum (a common
  companion to correctable error storms)
- Rolling "recent events" pane with timestamps, plus optional append-only
  event log file (`-l FILE`)
- Session summary on exit (totals per device, last error, recent events)
- Colors degrade gracefully: honored `NO_COLOR`, disabled when piped;
  Unicode glyphs fall back to ASCII on non-UTF-8 locales
- Single-shot text (`-d`) and JSON (`-j`) snapshots for scripting and
  periodic collection
- Passive mode (`-n`) that reads without clearing the hardware registers
- Everything read from sysfs — no `nvme-cli` or `udevadm` dependency

## Usage

```
sudo ./nvme_error.sh [OPTIONS]

Options:
    -d          Print one status snapshot and exit
    -j          Print one snapshot as JSON and exit
    -i SECONDS  Refresh interval for live mode (default: 2)
    -l FILE     Append every error event to FILE with full timestamps
    -n          Passive mode: do not clear AER status registers after
                reading (counts then reflect latched status, not deltas)
    -h          Show help and exit

Interactive keys (live mode):
    q  quit and print a session summary
    r  reset session counters and the recent-event list
```

## Example output

```
NVMe AER Monitor · host1 · updated 2026-07-17 15:27:00 · every 2s · up 00:12:34
  devices: 7  with errors: 2  events: 2 corr / 1 uncorr

  DEVICE   PCI ADDR SERIAL           MODEL                 LINK        NEW    CORR    UNC LAST ERROR
─────────────────────────────────────────────────────────────────────────────────────────────────────
● nvme0    c1:00.0  292410438E89     SAMSUNG MZQL21T9HCJR- Gen4 x4       -       0      0 -
● nvme2    c3:00.0  3224104DC1CD     INTEL SSDPF2KX038TZ   Gen4 x4       -     n/a      - no AER capability
● nvme4    01:00.0  292410438E84     SAMSUNG MZQL21T9HCJR- Gen4 x4      +2       2      0 15:27:00 RxErr AdvNF
● nvme5    02:00.0  3224104DC0ED     SAMSUNG MZQL21T9HCJR- Gen3 x4!      -       0      0 -
● nvme6    03:00.0  3224104DC085     SAMSUNG MZQL21T9HCJR- Gen4 x4       -       0      0 -
● nvme8    05:00.0  MSA250901B2      Micron_7450_MTFDKBG3T Gen4 x4      +1       0      1 15:27:00 CmpltTO
● -        c2:00.0  -                (no nvme driver)      Gen1 x1!      -       0      0 -

── recent events ────────────────────────────────────────────────────────────────────────────────────
  15:27:00  nvme8  uncorrectable: CmpltTO (status 0x00004000)
  15:27:00  nvme4  correctable: RxErr AdvNF (status 0x00002001)

 q quit · r reset counters · corr/unc = AER events since start
```

Column meanings:

| Column     | Meaning                                                                 |
|------------|-------------------------------------------------------------------------|
| `●`        | Health: green = clean, yellow = correctable errors seen, red = uncorrectable seen, dim = no AER capability |
| DEVICE     | NVMe controller name (`nvme0`, ...); `-` if no driver is bound           |
| PCI ADDR   | PCI `bus:dev.fn` of the controller                                      |
| SERIAL     | Drive serial number (from sysfs)                                        |
| MODEL      | Drive model string (from sysfs)                                         |
| LINK       | Current PCIe link; `!` (yellow) if below the drive's max speed or width |
| NEW        | Error events observed in the last poll interval                         |
| CORR / UNC | Correctable / uncorrectable events since the monitor started            |
| LAST ERROR | Time and decoded type(s) of the most recent error                       |

## JSON output

`-j` emits one snapshot suitable for collectors (`-jn` for a
non-destructive read that leaves the registers latched):

```json
{
  "version": "2.0.0",
  "timestamp": "2026-07-17T15:27:00Z",
  "host": "host1",
  "reset_after_read": true,
  "devices": [
    {
      "device": "nvme4",
      "pci_address": "0000:01:00.0",
      "serial": "292410438E84",
      "model": "SAMSUNG MZQL21T9HCJR-00A07",
      "firmware": "GDC5902Q",
      "link": {"speed": "16.0 GT/s", "width": "4", "max_speed": "16.0 GT/s", "max_width": "4", "degraded": false},
      "aer_supported": true,
      "correctable": {"status_raw": "00002001", "events": 2, "types": ["RxErr", "AdvNF"]},
      "uncorrectable": {"status_raw": "00000000", "events": 0, "types": []},
      "current_error": "00002001",
      "cumulative_errors": 2
    }
  ]
}
```

(`current_error` and `cumulative_errors` are kept for compatibility with
the v1 output format; `cumulative_errors` now counts decoded error events
rather than summing raw register values.)

## Event log format

With `-l FILE`, each error event is appended as one line:

```
2026-07-17T15:27:00+0200 session start (interval=2s, reset=yes)
2026-07-17T15:27:02+0200 nvme4 0000:01:00.0 corr status=0x00002001 types="RxErr AdvNF"
2026-07-17T15:27:14+0200 nvme8 0000:05:00.0 uncorr status=0x00004000 types="CmpltTO"
```

## How it works

- NVMe controllers are discovered by scanning PCI class `0x0108` under
  `/sys/bus/pci/devices`; controller names, serials and models come from
  `/sys/class/nvme`.
- Each poll reads the AER **Correctable Error Status** (`ECAP_AER+0x10`)
  and **Uncorrectable Error Status** (`ECAP_AER+0x04`) registers with
  `setpci`, decodes the set bits, then clears exactly the observed bits by
  writing the value back (the registers are write-1-to-clear). The next
  poll therefore reports only new events.
- These status registers are **latching bitmasks, not counters**: a set
  bit means that error type occurred *at least once* since last cleared.
  Counts shown are "error events observed" (one per bit per poll), so a
  sustained burst within one interval counts once. For exact rates, lower
  `-i` — or treat the numbers as an indicator, not a precise count.
- Polling reads the registers directly, so it works even on platforms
  where AER interrupts are handled by firmware and never reach the kernel
  log — but note that clearing the status bits is visible to any other
  AER consumer on the system.

## Dependencies

- bash >= 4.2
- `setpci` (pciutils package)
- Linux sysfs (`/sys/bus/pci`, `/sys/class/nvme`)

Root is required: `setpci` needs raw access to PCI config space.
