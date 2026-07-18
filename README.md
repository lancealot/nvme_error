# NVMe AER Error Monitor

A live, colorized monitor for PCIe Advanced Error Reporting (AER) on NVMe
controllers. It polls the AER capability registers at **both ends of each
drive's PCIe link** — the drive itself and its parent (host) port — decodes
correctable and uncorrectable status bits into human-readable error names,
and attributes every error to the end of the link that detected it, which
tells you which *direction* of the link is corrupting data.

The live view draws on the terminal's **alternate screen** (like `htop` or
`less`): your scrollback history is untouched while it runs and is restored
when you quit, at which point a session summary is printed so you keep a
record of what was observed.

## Directional monitoring

Each PCIe link has AER registers at both ends, and errors latch at the end
that detected them:

| Marker | Latched at | Suspect direction |
|--------|------------|-------------------|
| `↓`    | the drive's registers | host → drive traffic (the drive's receiver caught corruption) |
| `↑`    | the parent port's registers | drive → host traffic (the host side caught corruption) |

Reading the split:

- **`↓` only** — corruption on the way to the drive: host/adapter transmit
  side, or that segment of the channel.
- **`↑` only** — corruption on the way back: drive transmit side, or the
  same channel in the other direction.
- **Both ends** — shared cause: connector seating, reference clock, power,
  or a channel marginal in both directions.
- Caveat: replay-type errors (`Timeout`, `Rollover`) latch on the
  *transmitting* end, so they implicate the opposite direction — the
  per-type decode keeps that readable.

## Features

- Full-screen live view with in-place, flicker-free updates — never clears
  your terminal history
- Monitors **both** AER status registers (correctable `+0x10`,
  uncorrectable `+0x04`) at **both** link ends, with paired `↓`/`↑`
  counter columns and a `p` toggle for per-port sub-rows
- Decodes latched status bits into names matching kernel AER output
  (`RxErr`, `BadTLP`, `BadDLLP`, `AdvNF`, `CmpltTO`, `MalfTLP`, ...)
- **Drive detail screen** (`d` or a digit key): per-type × per-end error
  matrix, PCIe config (ASPM, MPS/MRRS, AER masks), uncorrectable
  **header-log decode** (the actual failing TLP: type, requester,
  address), extra temperature sensors, SMART health, and that drive's
  event history
- **Built-in read soak** (`t` in the detail screen): a strictly READ-ONLY
  background load generator to raise link duty cycle while you watch for
  errors — parallel `dd` readers with `O_DIRECT`, live GB/s readout, no
  external tools, and it never writes to the drive
- Link state that understands *deliberate* caps: a dim `*` marks a link
  running exactly at its configured Target Link Speed or port capability
  (expected), while a yellow `!` is reserved for links trained **below**
  even that — a real degradation signal
- Per-device health dot, serial, model, temperature colored against the
  drive's own warning/critical thresholds (kernel hwmon, no extra tools)
- Rolling recent-events pane with `↓`/`↑` attribution, plus optional
  append-only event log file (`-l FILE`)
- Session summary on exit with the directional split per device
- Single-shot text (`-d`) and JSON (`-j`) snapshots for scripting
- Passive mode (`-n`) that reads without clearing the hardware registers,
  using 0→1 edge detection so counts stay correct
- Colors honor `NO_COLOR`, degrade when piped; Unicode falls back to ASCII
  (`v`/`^` arrows) on non-UTF-8 locales

## Usage

```
sudo ./nvme_error.sh [OPTIONS]

Options:
    -d          Print one status snapshot and exit
    -j          Print one snapshot as JSON and exit
    -i SECONDS  Refresh interval for live mode (default: 2)
    -l FILE     Append every error event to FILE with full timestamps
    -n          Passive mode: read AER status without clearing it
    -h          Show help and exit

Interactive keys (live mode):
    q       quit and print a session summary
    r       reset session counters and the recent-event list
    p       toggle host-port sub-rows in the main table
    d, 0-9  open the drive detail screen (digit jumps to that nvme number)
    n / N   next / previous drive (detail screen)
    c       clear this drive's counters (detail screen)
    t       start/stop a READ-ONLY soak on this drive (detail screen)
    Esc, b  back to the main table
```

## Example output

```
NVMe AER Monitor · host1 · updated 2026-07-17 15:27:00 · every 2s · up 00:12:34
  devices: 7  with errors: 4  events: 2↓ 2↑ corr / 1↓ 0↑ unc

  DEVICE   PCI ADDR SERIAL           MODEL                  LINK       TEMP  NEW  ↓CORR ↓UNC  ↑CORR ↑UNC  LAST ERROR
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
● nvme0    c1:00.0  292410438E89     SAMSUNG MZQL21T9HCJR-0 Gen4 x4      72   +1      0    0      1    0  15:27:00 ↑BadTLP
  └ c0:01.1  root port                                                                -    -      1    0  15:27:00 ↑BadTLP
● nvme2    c3:00.0  3224104DC1CD     INTEL SSDPF2KX038TZ    Gen4 x4      38    -      -    -      0    0  no AER capability
● nvme4    01:00.0  292410438E84     SAMSUNG MZQL21T9HCJR-0 Gen4 x4      38   +2      2    0      0    0  15:27:00 ↓RxErr AdvNF
● nvme5    02:00.0  3224104DC0ED     SAMSUNG MZQL21T9HCJR-0 Gen3 x4*     38    -      0    0      0    0  -
● nvme8    05:00.0  MSA250901B2      Micron_7450_MTFDKBG3T8 Gen4 x4      38   +1      0    1      -    -  15:27:00 ↓CmpltTO
● -        c2:00.0  -                (no nvme driver)       Gen1 x1!      -    -      0    0      0    0  -

── recent events ───────────────────────────────────────────────────────────────────────────────────────────────────
  15:27:00  nvme0  ↑ port c0:01.1  correctable: BadTLP (status 0x00000040)
  15:27:00  nvme8  ↓ drive  uncorrectable: CmpltTO (status 0x00004000)
  15:27:00  nvme4  ↓ drive  correctable: RxErr AdvNF (status 0x00002001)

 q quit · r reset · p ports · d/0-9 detail · ↓ at drive · ↑ at host port · * capped
```

Column meanings:

| Column        | Meaning                                                                 |
|---------------|-------------------------------------------------------------------------|
| `●`           | Health: green = clean, yellow = correctable errors seen (either end), red = uncorrectable seen, dim = no AER capability |
| DEVICE        | NVMe controller name; `-` if no driver is bound                          |
| PCI ADDR      | PCI `bus:dev.fn` of the controller                                      |
| SERIAL, MODEL | Drive identity (from sysfs)                                             |
| LINK          | Trained link; dim `*` = capped by config/port (expected), yellow `!` = below even the cap (degraded) |
| TEMP          | Composite temperature in °C; yellow/red at the drive's warning/critical thresholds; `-` if unavailable |
| NEW           | Error events observed in the last poll interval (both ends)             |
| ↓CORR / ↓UNC  | Correctable / uncorrectable events latched at the **drive** since start |
| ↑CORR / ↑UNC  | Correctable / uncorrectable events latched at the **host port** since start |
| LAST ERROR    | Time, end marker, and decoded type(s) of the most recent error on the link |

## Drive detail screen

Press `d` (or a digit) to open one drive full-screen:

- **AER matrix** — per-error-type counters, `↓drive` and `↑port` side by side
- **Link block** — both ends' speed/width, the port's configured Target
  Link Speed, capped/degraded state
- **Config** — ASPM state, Max Payload Size, Max Read Request Size, and
  any masked correctable error types (a masked `AdvNF` explains a drive
  that seems mysteriously quiet)
- **Header log** — on an uncorrectable error, the AER capability captures
  the failing TLP's header; the screen decodes it (e.g.
  `MRd from 00:03.1 addr 0xfe800000`) so you can see *what transaction*
  failed
- **Health** — all hwmon temperature sensors plus, when nvme-cli is
  installed, SMART spare/used/media-errors/unsafe-shutdowns
- **Events** — this drive's recent error history and session totals

## Read soak (safe link stress)

Some marginal links only error under traffic. Press `t` in the detail
screen to start a **read-only** soak on that drive: parallel `dd` readers
(`bs=1M`, `O_DIRECT`) sweep the namespace to keep the link busy while the
monitor watches both ends. A status line shows readers, elapsed time, and
approximate throughput; press `t` again to stop, and quitting the monitor
always stops it too.

Safety properties:

- It only ever **reads** — no write is issued, so existing data is never
  modified, regardless of what is (or isn't) on the drive.
- `O_DIRECT` bypasses the page cache so the traffic actually crosses the
  PCIe link (with a plain-read fallback where `O_DIRECT` is unsupported).
- It does add I/O load and latency on that drive while running — expect
  reduced application performance until you stop it.

Note on direction: reads move data drive→host, so a read soak primarily
exercises the `↑` detection path (plus request/ACK traffic downstream).
That's the safe subset — write-direction payload stress cannot be
generated without writing, which this tool deliberately never does. For
even heavier or longer runs, external `fio --readonly` jobs work fine
alongside the monitor.

## JSON output

`-j` emits one snapshot (`-jn` for a non-destructive read):

```json
{
  "version": "3.0.0",
  "timestamp": "2026-07-17T15:27:00Z",
  "host": "host1",
  "reset_after_read": true,
  "devices": [
    {
      "device": "nvme5",
      "pci_address": "0000:02:00.0",
      "serial": "3224104DC0ED",
      "model": "SAMSUNG MZQL21T9HCJR-00A07",
      "firmware": "GDC5902Q",
      "link": {"speed": "8.0 GT/s", "width": "4", "max_speed": "16.0 GT/s",
               "max_width": "4", "target_speed": "8.0 GT/s",
               "degraded": false, "capped": true},
      "temperature_c": 38,
      "aer_supported": true,
      "correctable":   {"status_raw": "00000000", "events": 0, "types": []},
      "uncorrectable": {"status_raw": "00000000", "events": 0, "types": []},
      "host_port": {
        "pci_address": "0000:00:01.3",
        "aer_supported": true,
        "correctable":   {"status_raw": "00000000", "events": 0, "types": []},
        "uncorrectable": {"status_raw": "00000000", "events": 0, "types": []}
      },
      "current_error": "00000000",
      "cumulative_errors": 0
    }
  ]
}
```

(`host_port` is `null` for controllers with no visible parent port.
`current_error` and `cumulative_errors` remain for v1 compatibility.)

## Event log format

With `-l FILE`, each error event is appended as one line; the address
field is the register's owner (drive, or its port for `↑` events):

```
2026-07-17T15:27:00+0200 session start (interval=2s, reset=yes)
2026-07-17T15:27:02+0200 nvme4 0000:01:00.0 ↓corr status=0x00002001 types="RxErr AdvNF"
2026-07-17T15:27:14+0200 nvme0 0000:c0:01.1 ↑corr status=0x00000040 types="BadTLP"
```

## How it works

- NVMe controllers are discovered by scanning PCI class `0x0108` under
  `/sys/bus/pci/devices`; each drive's parent port comes from its position
  in the PCI tree, and controller names/serials/models from
  `/sys/class/nvme`.
- Each poll reads the AER **Correctable** (`+0x10`) and **Uncorrectable**
  (`+0x04`) status registers with `setpci` at the drive *and* its parent
  port, decodes newly set bits, then clears exactly the observed bits by
  writing the value back (write-1-to-clear) at both ends. With `-n`
  nothing is written; new events are detected as 0→1 transitions between
  polls instead (a re-latched bit that never cleared in between cannot be
  distinguished, which is the price of passive mode).
- These status registers are **latching bitmasks, not counters**: counts
  are "error events observed" (one per bit per poll), so a burst within
  one interval counts once. Lower `-i` for finer rates.
- Because the script clears status bits at the root port too, other AER
  consumers (the kernel's AER service, rasdaemon) may see fewer events
  while it runs; use `-n` if something else owns those registers.
- Dual-function (dual-port) drives share one upstream port; its `↑`
  counters are shared across those functions by design. Drives behind a
  PCIe switch get their switch downstream port monitored; the switch's
  own uplink is not yet covered.
- The capped-link check reads the port's **Target Link Speed** (Link
  Control 2 register): running exactly at the configured target (or the
  port's own max) is reported as capped (`*`), not degraded (`!`).
- Temperature comes from the kernel's NVMe hwmon sensor (kernel >= 5.5,
  `CONFIG_NVME_HWMON`), including the drive's warning/critical thresholds
  (WCTEMP/CCTEMP); `nvme smart-log` is used only as a fallback.

## Dependencies

- bash >= 4.2
- `setpci` (pciutils package)
- Linux sysfs (`/sys/bus/pci`, `/sys/class/nvme`)
- `dd` (coreutils) for the read soak
- nvme-cli — **optional**: temperature fallback on pre-5.5 kernels and
  the SMART block in the detail screen; everything else works without it

Root is required: `setpci` needs raw access to PCI config space.
