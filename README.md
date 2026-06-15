# SP420 Thermal Label Print Server

Turn a Raspberry Pi + iDPRT SP420 into a **zero-config network label printer** that works with **any device on your LAN**. Print 4×6 labels from any app — just tap Print and pick the printer. No cloud, no tokens, no drivers to install.

```
Any device ──IPP──→ Pi (CUPS) ──TSPL──→ iDPRT SP420 via USB
     ↑                   ↑
  Auto-discovered     Converts PDF→raster→TSPL
  via mDNS/AirPrint   locally (zero tokens)
```

## Features

- **Driverless** — appears automatically in your print dialog on Linux, macOS, Android
- **AirPrint / IPP Everywhere / Mopria** compliant
- **Zero token cost** — all conversion happens locally on the Pi
- **Works with any app** that can print — browser, office suite, label designer, scanner PWA
- **Configurable** — label size, print speed, density, gap sensor via YAML config
- **One-command setup** — `curl | sudo bash`
- **Windows support** via IPP or raw TCP socket bridge

## Hardware

| Component | Details |
|-----------|---------|
| **Printer** | iDPRT SP420 thermal label printer (203 DPI) |
| **Host** | Raspberry Pi (any model with USB) — **Raspbian/Debian Bookworm+** |
| **Connection** | USB — the Pi must be plugged directly into the printer |
| **Labels** | 4×6 inch (101.6×152.4mm) die-cut thermal labels, gap sensor |
| **Network** | WiFi or Ethernet — printer is discoverable on the LAN |

## Quick Start

### One-line install

On your Raspberry Pi:

```bash
curl -sSL https://raw.githubusercontent.com/cheeseb1234/sp420-label-print-server/main/setup.sh | sudo bash
```

This installs everything: CUPS, Avahi/mDNS, the PDF→TSPL backend, creates the queue, and advertises the printer on your network.

### Or clone and run

```bash
git clone https://github.com/cheeseb1234/sp420-label-print-server
cd sp420-label-print-server
sudo bash setup.sh
```

## Adding the Printer on Your Devices

| Platform | How to add |
|----------|------------|
| **Linux** | Settings → Printers → Add → should auto-discover as **"SP420 Thermal Label Printer 4x6"** |
| **macOS** | System Settings → Printers & Scanners → Add → auto-discover or enter `ipp://pi-hostname:631/printers/SP420-Label` |
| **Android** | Install [Mopria Print Service](https://play.google.com/store/apps/details?id=org.mopria.print.mopriaprintservice) → it auto-discovers the printer |
| **Windows** | Settings → Bluetooth & devices → Printers & scanners → Add device → **"The printer I want isn't listed"** → Add by IPP → `ipp://pi-ip:631/printers/SP420-Label` |
| **ChromeOS** | Settings → Printers → Add Printer → IPP → `ipp://pi-ip:631/printers/SP420-Label` |

## Printing a Label

Once added, just Print from any app and select the SP420 printer:

```bash
# From the command line:
lp -d SP420-Label my-label.pdf
lp -d SP420-Label -n 5 my-label.pdf   # 5 copies

# From any app:
# File → Print → Select "SP420 Thermal Label Printer 4x6" → Print
```

The printer queue converts your PDF to the thermal printer's native TSPL language automatically.

## Configuration

After setup, edit `/etc/sp420-label-printer/config.yaml`:

```yaml
device: /dev/usb/lp0
label_width_mm: 101.6    # Label width  (4 inches)
label_height_mm: 152.4   # Label height (6 inches)
dpi: 203
gap_mm: 3
speed: 4                 # 1-6 (higher = faster, may reduce quality)
density: 8               # 1-15 (higher = darker)
direction: 1             # 0 or 1 (print orientation)
media_sensor: gap        # "gap" for die-cut labels, "bline" for black mark
packing_strategy: A      # A = white→bit=1 (default), B = black→bit=1
```

After changing config, restart CUPS:

```bash
sudo systemctl restart cups
```

## Architecture

```
                     ┌─────────────────────────┐
                     │   Client Device          │
                     │  (Linux/Mac/Android/Win) │
                     └──────────┬──────────────┘
                                │ IPP (PDF)
                                ▼
┌────────────────────────────────────────────────────┐
│  Raspberry Pi (pi.kellogg)                         │
│                                                    │
│  ┌─────────┐   ┌──────────────┐   ┌────────────┐  │
│  │ Avahi   │   │ CUPS         │   │ Python     │  │
│  │ mDNS    │──▶│ :631         │──▶│ Backend    │  │
│  │ Advert. │   │ SP420-Label  │   │ PDF→TSPL  │  │
│  └─────────┘   └──────────────┘   └─────┬──────┘  │
│                                          │         │
│                                    /dev/usb/lp0    │
│                                          │         │
└──────────────────────────────────────────┼─────────┘
                                           │
                                    ┌──────┴──────┐
                                    │  iDPRT SP420 │
                                    │  Thermal     │
                                    │  Label       │
                                    │  Printer     │
                                    └─────────────┘
```

### Data flow

1. **Client** sends a PDF via IPP (Internet Printing Protocol) to CUPS on the Pi
2. **CUPS** queues the job and passes the PDF to the custom backend
3. **Backend** (`label-thermal.py`):
   - Renders the PDF at 203 DPI using `pdftoppm` (Poppler)
   - Converts to 1-bit monochrome via Pillow
   - Rotates landscape→portrait for 4×6 label stock
   - Packs pixels into TSPL BITMAP command (Strategy A: white→bit=1, mode=1)
   - Writes raw TSPL data to `/dev/usb/lp0`
4. **iDPRT SP420** receives the TSPL command and prints the label

Everything runs locally on the Pi — **no cloud services, no API tokens, no ongoing costs**.

## Project Structure

```
sp420-label-print-server/
├── setup.sh                  ← One-command installer
├── config.example.yaml       ← Configuration reference
├── backend/
│   └── label-thermal.py      ← CUPS backend (PDF→TSPL converter)
├── ppd/
│   └── sp420.ppd             ← Printer PPD file
├── avahi/
│   └── sp420-label.service.in ← mDNS service template
├── docs/
│   └── troubleshooting.md    ← Debugging guide
└── scripts/
    └── test-print.sh         ← Test label generator
```

## Troubleshooting

```bash
# Check printer queue status
lpstat -p SP420-Label -l

# View queued/completed jobs
lpstat -o SP420-Label
lpstat -W completed SP420-Label

# Check CUPS logs
sudo journalctl -u cups -n 50 --no-pager

# Test USB connection
ls -la /dev/usb/lp0
lsusb | grep -i "idprt\|sp420"

# Check mDNS advertising
avahi-browse -rt _ipp._tcp

# Force a test print
lp -d SP420-Label /path/to/test.pdf
```

### Common issues

- **Nothing prints**: Check `/dev/usb/lp0` exists. Is the printer powered on? USB cable connected?
- **CUPS queue disabled**: `sudo cupsenable SP420-Label`
- **Blank label / inverted**: Check `packing_strategy` in config — should be `A` for most setups
- **Label feeds continuously**: Wrong media sensor — set `media_sensor: gap` in config
- **Job stuck in queue**: `sudo cancel -a SP420-Label` to clear

## License

MIT
