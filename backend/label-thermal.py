#!/usr/bin/env python3
"""
SP420 Thermal Label Printer — CUPS backend

Converts incoming PDF print jobs to TSPL raster BITMAP and writes
directly to the iDPRT SP420 via /dev/usb/lp0.

Strategy A: white→bit=1, black→bit=0, BITMAP mode=1
  The printer inverts mode=1 data: white→no-ink, black→ink.

Installation:
  sudo cp label-thermal.py /usr/lib/cups/backend/label-thermal
  sudo chmod 700 /usr/lib/cups/backend/label-thermal
  sudo chown root:root /usr/lib/cups/backend/label-thermal

CUPS calling convention (no device_uri argument — comes via DEVICE_URI env):
  backend job-id user title copies options [file]
  No args → list URI scheme for lpinfo -v
"""

import sys
import os
import subprocess
import tempfile
import yaml
from PIL import Image

# ── Defaults (overridden by config) ─────────────────────────────────────
CONFIG_PATH = "/etc/sp420-label-printer/config.yaml"

DEFAULTS = {
    "device": "/dev/usb/lp0",
    "label_width_mm": 101.6,
    "label_height_mm": 152.4,
    "dpi": 203,
    "gap_mm": 3,
    "speed": 4,
    "density": 8,
    "direction": 1,
    "reference": [0, 0],
    "media_sensor": "gap",
    "black_mark_offset": 0,
    "packing_strategy": "A",  # A = white→bit=1 mode=1; B = black→bit=1 mode=0
}


def load_config():
    """Load config, falling back to defaults."""
    cfg = dict(DEFAULTS)
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH) as f:
                user = yaml.safe_load(f) or {}
            cfg.update(user)
        except Exception as e:
            sys.stderr.write(f"Warning: failed to load {CONFIG_PATH}: {e}\n")
    return cfg


def pdf_to_tspl(pdf_data, copies=1, cfg=None):
    """Convert PDF bytes to TSPL BITMAP command suitable for SP420."""
    if cfg is None:
        cfg = DEFAULTS

    W = round(cfg["label_width_mm"] / 25.4 * cfg["dpi"])
    H = round(cfg["label_height_mm"] / 25.4 * cfg["dpi"])

    with tempfile.TemporaryDirectory() as tmpdir:
        pdf_path = os.path.join(tmpdir, "input.pdf")
        with open(pdf_path, "wb") as f:
            f.write(pdf_data)

        # Render PDF at configured DPI via pdftoppm → PNG
        result = subprocess.run(
            ["pdftoppm", "-png", "-r", str(cfg["dpi"]),
             pdf_path, os.path.join(tmpdir, "page")],
            capture_output=True, timeout=30
        )
        if result.returncode != 0:
            raise RuntimeError(f"pdftoppm failed: {result.stderr.decode()}")

        # Locate rendered PNG
        for fname in sorted(os.listdir(tmpdir)):
            if fname.endswith(".png"):
                actual_png = os.path.join(tmpdir, fname)
                break
        else:
            raise RuntimeError("pdftoppm produced no PNG output")

        img_rgb = Image.open(actual_png).convert("RGB")
        # Threshold to 1-bit (clean, no dithering)
        img_bw = img_rgb.convert("L").point(
            lambda x: 255 if x > 200 else 0, mode="1"
        )

        # Rotate: PDF is landscape (6×4), label stock is portrait (4×6)
        img = img_bw.rotate(-90, expand=True)
        # Crop to exact label dimensions (pdftoppm may pad slightly)
        img = img.crop((0, 0, min(img.width, W), min(img.height, H)))
        w, h = img.size
        bw = (w + 7) // 8

        # Pack bits
        if cfg["packing_strategy"] == "A":
            # Strategy A: white→bit=1, black→bit=0, mode=1
            payload = bytearray()
            for y in range(h):
                for bx in range(bw):
                    byte_val = 0
                    for bit in range(8):
                        px_x = bx * 8 + bit
                        if px_x < w and img.getpixel((px_x, y)) != 0:
                            byte_val |= (1 << (7 - bit))
                    payload.append(byte_val)
            bitmap_mode = 1
        else:
            # Strategy B: black→bit=1, white→bit=0, mode=0
            payload = bytearray()
            for y in range(h):
                for bx in range(bw):
                    byte_val = 0
                    for bit in range(8):
                        px_x = bx * 8 + bit
                        if px_x < w and img.getpixel((px_x, y)) == 0:
                            byte_val |= (1 << (7 - bit))
                    payload.append(byte_val)
            bitmap_mode = 0

        # Build TSPL
        gap = cfg["gap_mm"]
        bm_offset = cfg.get("black_mark_offset", 0)
        if cfg["media_sensor"] == "bline":
            gap_line = f"GAP {gap} mm,{bm_offset} mm\r\nBLINE {bm_offset} mm,0 mm\r\n"
        else:
            gap_line = f"GAP {gap} mm,0 mm\r\n"

        tspl = bytearray()
        tspl += f"SIZE {cfg['label_width_mm']} mm,{cfg['label_height_mm']} mm\r\n".encode()
        tspl += gap_line.encode()
        tspl += f"SPEED {cfg['speed']}\r\n".encode()
        tspl += f"DENSITY {cfg['density']}\r\n".encode()
        tspl += f"DIRECTION {cfg['direction']}\r\n".encode()
        tspl += f"REFERENCE {cfg['reference'][0]},{cfg['reference'][1]}\r\n".encode()
        tspl += b"CLS\r\n"
        tspl += f"BITMAP 0,0,{bw},{h},{bitmap_mode},\r\n".encode()
        tspl += bytes(payload)
        tspl += f"\r\nPRINT {copies},1\r\n".encode()

        return tspl


def write_to_printer(data, device):
    """Write raw TSPL to device."""
    with open(device, "wb") as f:
        f.write(data)


# ── CUPS Backend Interface ─────────────────────────────────────────────

def list_schemes():
    print('direct label-thermal "Unknown" "Thermal Label Printer (iDPRT SP420)"')


def print_job(job_id, user, title, copies, options, filename=None, cfg=None):
    if filename and os.path.exists(filename):
        with open(filename, "rb") as f:
            pdf_data = f.read()
    else:
        pdf_data = sys.stdin.buffer.read()

    if not pdf_data or len(pdf_data) < 100:
        sys.stderr.write(f"ERROR: No valid PDF data for job {job_id}\n")
        sys.exit(1)

    n = int(copies) if copies and copies.isdigit() else 1
    tspl = pdf_to_tspl(pdf_data, copies=n, cfg=cfg)
    write_to_printer(tspl, cfg["device"])
    sys.stderr.write(
        f"Job {job_id}: {title} — {len(tspl)} bytes, {n} copy/copies "
        f"to {cfg['device']}\n"
    )


# ── Entry Point ─────────────────────────────────────────────────────────

if __name__ == "__main__":
    if len(sys.argv) < 6:
        list_schemes()
        sys.exit(0)

    cfg = load_config()

    try:
        print_job(
            sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4],
            sys.argv[5] if len(sys.argv) > 5 else "",
            sys.argv[6] if len(sys.argv) > 6 else None,
            cfg=cfg,
        )
        sys.exit(0)
    except Exception as e:
        sys.stderr.write(f"ERROR: {e}\n")
        sys.exit(1)
