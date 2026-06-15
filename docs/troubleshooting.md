# Troubleshooting Guide

## Printer Not Printing

### Check physical connection
```bash
ls -la /dev/usb/lp0
lsusb | grep -i "idprt\|sp420"
```

If no device: check USB cable, power cycle the printer, try a different USB port.

### Check CUPS backend
```bash
sudo /usr/lib/cups/backend/label-thermal
```
Should output: `direct label-thermal "Unknown" "Thermal Label Printer (iDPRT SP420)"`

### Test backend directly
```bash
sudo /usr/lib/cups/backend/label-thermal 999 testuser "Test" 1 "" /path/to/test.pdf
```

### Check CUPS logs
```bash
sudo journalctl -u cups -n 100 --no-pager
```

### Check printer queue
```bash
lpstat -p SP420-Label -l
lpstat -o SP420-Label
```

If disabled: `sudo cupsenable SP420-Label`

## Print Quality Issues

### Label is inverted (white text on black background)
Edit `/etc/sp420-label-printer/config.yaml` and toggle `packing_strategy`:
- If `A`, change to `B`
- If `B`, change to `A`

Then restart: `sudo systemctl restart cups`

### Too light or too dark
Adjust `density` in config (1-15, default 8). Lower = lighter, higher = darker.

### Labels feed continuously
The media sensor is wrong. Ensure `media_sensor: gap` in config (for die-cut labels with gaps, not black marks).

### Wrong label size
Adjust `label_width_mm` and `label_height_mm` in config. Common sizes:
- 4×6: 101.6 × 152.4 mm
- 2×4: 50.8 × 101.6 mm
- 3×5: 76.2 × 127.0 mm

## Auto-Discovery Issues

### Printer not showing up on my device

Check mDNS is working on the Pi:
```bash
avahi-browse -rt _ipp._tcp
```
Should show "SP420 Thermal Label Printer 4x6"

If not:
```bash
sudo systemctl status avahi-daemon
sudo systemctl restart avahi-daemon
```

### Mac says "Printer uses unsupported software"
This happens when macOS tries AirPrint but the printer doesn't support URF format. Add the printer manually via IPP:
- Open System Settings → Printers & Scanners → Add Printer → IPP tab
- Enter: `ipp://pi-ip:631/printers/SP420-Label`
- It will ask for a driver — select "Generic PostScript Printer" or "Generic IPP Everywhere Printer"

### Windows doesn't auto-discover
Windows requires manual IPP add. Use:
1. Settings → Bluetooth & devices → Printers & scanners
2. Add device → "The printer I want isn't listed"
3. Select "Add by IPP"
4. Enter: `ipp://pi-ip:631/printers/SP420-Label`
5. Select "Generic IPP Everywhere Printer" as the driver

## Printer Configuration

The iDPRT SP420 has locked settings stored in firmware (set via Windows utility):
- **GAP**: 3 mm (do not change unless recalibrating)
- **SPEED**: 4
- **DENSITY**: 8
- **DIRECTION**: 1
- **REFERENCE**: 0,0

These are set as defaults in `/etc/sp420-label-printer/config.yaml` and should match the physical printer settings.

**Never change the media sensor to BLINE** unless you're using black-mark label stock. The SP420's black-mark sensor is centered and standard labels don't have centered marks — BLINE mode causes continuous feed.
