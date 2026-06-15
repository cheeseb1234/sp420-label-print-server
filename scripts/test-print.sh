#!/usr/bin/env bash
# Generate a simple test label and print it
set -euo pipefail

QUEUE="${1:-SP420-Label}"
TEST_PDF="/tmp/sp420-test-label.pdf"

python3 << 'PYEOF'
from PIL import Image, ImageDraw, ImageFont
from datetime import date

W, H = 1800, 1200
img = Image.new("RGB", (W, H), "white")
d = ImageDraw.Draw(img)

# Border
d.rectangle([20, 20, W-20, H-20], outline="black", width=6)

# Title
d.text((60, 80), "SP420 THERMAL LABEL PRINTER", fill="black")
d.text((60, 160), "Test Label", fill="black")

# Info
d.text((60, 300), f"Date: {date.today()}", fill="black")
d.text((60, 380), f"Queue: {QUEUE}", fill="black")
d.text((60, 460), "4x6 inch — 203 DPI", fill="black")

# Crosshairs
cx, cy = W//2, H//2
d.line([cx-30, cy, cx+30, cy], fill="black", width=3)
d.line([cx, cy-30, cx, cy+30], fill="black", width=3)

img.save("/tmp/sp420-test-label.pdf")
print(f"Test label saved: /tmp/sp420-test-label.pdf")
PYEOF

echo ""
echo "Printing to queue: $QUEUE"
echo ""
lp -d "$QUEUE" "$TEST_PDF" && echo "✅ Sent!" || echo "❌ Failed"
echo ""
echo "Check: lpstat -o $QUEUE"
