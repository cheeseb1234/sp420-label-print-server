#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════
# SP420 Thermal Label Printer — Self-Deploying Setup
# ═══════════════════════════════════════════════════════════════════════
# Targets: Raspberry Pi (Raspbian/Debian Bookworm+), any Linux with CUPS
# Printer: iDPRT SP420 via USB (/dev/usb/lp0)
# ═══════════════════════════════════════════════════════════════════════
# Usage:
#   curl -sSL https://raw.githubusercontent.com/USER/sp420-label-print-server/main/setup.sh | sudo bash
#   # Or after cloning:
#   sudo bash setup.sh
# ═══════════════════════════════════════════════════════════════════════

# ── Configuration ──────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && pwd)"

BACKEND_SRC="$REPO_ROOT/backend/label-thermal.py"
PPD_SRC="$REPO_ROOT/ppd/sp420.ppd"
AVAHI_TEMPLATE="$REPO_ROOT/avahi/sp420-label.service.in"
CONFIG_EXAMPLE="$REPO_ROOT/config.example.yaml"

BACKEND_DEST="/usr/lib/cups/backend/label-thermal"
PPD_DEST="/usr/share/cups/model/sp420.ppd"
AVAHI_DEST="/etc/avahi/services/sp420-label.service"
CONFIG_DIR="/etc/sp420-label-printer"
CONFIG_DEST="$CONFIG_DIR/config.yaml"

QUEUE_NAME="SP420-Label"
PRINTER_DESC="SP420 Thermal Label Printer 4x6"

# ── Colors ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC} $*"; }

# ── Pre-flight ─────────────────────────────────────────────────────────
preflight() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  SP420 Thermal Label Printer — Setup                   ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    # Must be root
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root (use sudo)."
        exit 1
    fi

    # OS detection
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        info "OS: $PRETTY_NAME"
    else
        warn "Unknown OS — proceeding with best-effort install."
    fi

    # Architecture
    ARCH=$(uname -m)
    info "Architecture: $ARCH"

    # Check printer connected
    if [[ -c /dev/usb/lp0 ]]; then
        ok "Printer detected at /dev/usb/lp0"
        lsusb 2>/dev/null | grep -i "idprt\|sp420" && ok "USB vendor: iDPRT SP420" || true
    else
        warn "No printer at /dev/usb/lp0. Plug in the iDPRT SP420 and try again."
        warn "Continuing anyway — you can configure the device path later."
    fi
}

# ── Install Dependencies ──────────────────────────────────────────────
install_deps() {
    echo ""
    info "Step 1: Installing system dependencies..."

    apt-get update -qq

    # Core packages
    DEPS=(
        cups cups-client cups-ipp-utils
        avahi-daemon avahi-utils
        python3 python3-pip python3-pil
        poppler-utils
        printer-driver-all  # for standard backends
    )

    apt-get install -y -qq "${DEPS[@]}" 2>&1 | tail -1
    ok "System packages installed"

    # Python packages
    info "Installing Python dependencies..."
    pip3 install pyyaml --quiet 2>&1 | tail -1 || {
        # Fallback if pip3 not available
        apt-get install -y -qq python3-yaml 2>&1 | tail -1
    }
    ok "Python dependencies installed"

    # Enable and start services
    systemctl enable --now cups 2>/dev/null || true
    systemctl enable --now avahi-daemon 2>/dev/null || true
    systemctl enable --now cups-browsed 2>/dev/null || true
}

# ── Install CUPS Backend ──────────────────────────────────────────────
install_backend() {
    echo ""
    info "Step 2: Installing CUPS backend..."

    mkdir -p "$(dirname "$BACKEND_DEST")"
    if [[ -f "$BACKEND_SRC" ]]; then
        cp "$BACKEND_SRC" "$BACKEND_DEST"
    else
        # Download from GitHub if run standalone
        warn "Backend source not found locally — downloading..."
        curl -sSL "https://raw.githubusercontent.com/cheeseb1234/sp420-label-print-server/main/backend/label-thermal.py" \
            -o "$BACKEND_DEST"
    fi

    chmod 700 "$BACKEND_DEST"
    chown root:root "$BACKEND_DEST"

    # Verify
    if "$BACKEND_DEST" 2>/dev/null | grep -q "label-thermal"; then
        ok "Backend installed and responding"
    else
        err "Backend verification failed"
        exit 1
    fi
}

# ── Install PPD ───────────────────────────────────────────────────────
install_ppd() {
    echo ""
    info "Step 3: Installing PPD (printer description)..."

    mkdir -p "$(dirname "$PPD_DEST")"
    if [[ -f "$PPD_SRC" ]]; then
        cp "$PPD_SRC" "$PPD_DEST"
    else
        warn "PPD not found locally — downloading..."
        curl -sSL "https://raw.githubusercontent.com/cheeseb1234/sp420-label-print-server/main/ppd/sp420.ppd" \
            -o "$PPD_DEST"
    fi

    chmod 644 "$PPD_DEST"
    ok "PPD installed at $PPD_DEST"
}

# ── Install Config ────────────────────────────────────────────────────
install_config() {
    echo ""
    info "Step 4: Setting up configuration..."

    mkdir -p "$CONFIG_DIR"

    if [[ ! -f "$CONFIG_DEST" ]]; then
        if [[ -f "$CONFIG_EXAMPLE" ]]; then
            cp "$CONFIG_EXAMPLE" "$CONFIG_DEST"
        else
            # Write default config
            cat > "$CONFIG_DEST" << 'CONF'
# SP420 Thermal Label Printer — Configuration
device: /dev/usb/lp0
label_width_mm: 101.6
label_height_mm: 152.4
dpi: 203
gap_mm: 3
speed: 4
density: 8
direction: 1
reference: [0, 0]
media_sensor: gap
packing_strategy: A
CONF
        fi
        info "Default config written to $CONFIG_DEST"
        info "  Edit this file to change label size, speed, density, etc."
    else
        info "Config already exists at $CONFIG_DEST (keeping existing)"
    fi
}

# ── Create CUPS Queue ─────────────────────────────────────────────────
create_queue() {
    echo ""
    info "Step 5: Creating CUPS printer queue..."

    # Remove existing queue if present (so we can recreate cleanly)
    lpadmin -x "$QUEUE_NAME" 2>/dev/null || true

    # Create queue with PPD (driver-based, not raw)
    lpadmin -p "$QUEUE_NAME" -E \
        -v "label-thermal:///dev/usb/lp0" \
        -P "$PPD_DEST" \
        -o printer-is-shared=true \
        -o policy=allowall \
        -o PageSize=4x6Label \
        -D "$PRINTER_DESC" \
        -L "Local" 2>&1

    cupsaccept "$QUEUE_NAME"
    cupsenable "$QUEUE_NAME"

    # Verify
    if lpstat -p "$QUEUE_NAME" 2>/dev/null | grep -q "idle"; then
        ok "Queue '$QUEUE_NAME' created and idle"
    else
        err "Queue creation may have failed — check 'lpstat -p $QUEUE_NAME'"
    fi
}

# ── Install Avahi Service ─────────────────────────────────────────────
install_avahi() {
    echo ""
    info "Step 6: Installing Avahi/mDNS service for auto-discovery..."

    # Generate stable UUID
    PRINTER_UUID=$(python3 -c "
import uuid
print(uuid.uuid5(uuid.NAMESPACE_DNS, 'sp420-label.printer'))
")

    # Get hostname
    PI_HOSTNAME=$(hostname -f 2>/dev/null || hostname)

    if [[ -f "$AVAHI_TEMPLATE" ]]; then
        # Substitute template variables
        sed \
            -e "s/__PRINTER_UUID__/$PRINTER_UUID/g" \
            -e "s/__PI_HOSTNAME__/$PI_HOSTNAME/g" \
            "$AVAHI_TEMPLATE" > "$AVAHI_DEST"
    else
        warn "Avahi template not found — writing default service file..."
        cat > "$AVAHI_DEST" << AVAHI
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">SP420 Thermal Label Printer 4x6</name>
  <service>
    <type>_ipp._tcp</type>
    <subtype>_universal._sub._ipp._tcp</subtype>
    <port>631</port>
    <txt-record>txtvers=1</txt-record>
    <txt-record>qtotal=1</txt-record>
    <txt-record>rq=1</txt-record>
    <txt-record>pdl=application/pdf</txt-record>
    <txt-record>product=(iDPRT SP420)</txt-record>
    <txt-record>kind=document</txt-record>
    <txt-record>priority=0</txt-record>
    <txt-record>mopria-certified=1.3</txt-record>
    <txt-record>UUID=$PRINTER_UUID</txt-record>
    <txt-record>adminurl=http://$PI_HOSTNAME:631/printers/SP420-Label</txt-record>
    <txt-record>printer-type=0x0084</txt-record>
    <txt-record>printer-state=3</txt-record>
    <txt-record>printer-uri-supported=ipp://$PI_HOSTNAME:631/printers/SP420-Label</txt-record>
    <txt-record>note=Thermal Label Printer (4x6)</txt-record>
    <txt-record>Color=F</txt-record>
    <txt-record>Duplex=F</txt-record>
    <txt-record>Copies=T</txt-record>
    <txt-record>Collate=F</txt-record>
  </service>
</service-group>
AVAHI
    fi

    chmod 644 "$AVAHI_DEST"
    systemctl restart avahi-daemon
    ok "Avahi service installed and restarted"
}

# ── Configure CUPS for Network Access ────────────────────────────────
configure_cups_network() {
    echo ""
    info "Step 7: Configuring CUPS for network access..."

    CUPS_CONF="/etc/cups/cupsd.conf"

    # Ensure CUPS listens on all interfaces
    if grep -q "^Listen localhost:631" "$CUPS_CONF" 2>/dev/null; then
        sed -i 's/^Listen localhost:631/Listen 0.0.0.0:631/' "$CUPS_CONF"
        ok "CUPS listening on all interfaces"
    fi

    # Enable browsing/DNS-SD
    sed -i 's/^Browsing Off/Browsing On/' "$CUPS_CONF" 2>/dev/null || true
    if ! grep -q "^BrowseLocalProtocols" "$CUPS_CONF" 2>/dev/null; then
        echo "BrowseLocalProtocols dnssd" >> "$CUPS_CONF"
    fi
    ok "CUPS browsing and DNS-SD enabled"

    # Ensure print job access from LAN
    if ! grep -q "Allow @LOCAL" "$CUPS_CONF" 2>/dev/null; then
        # Insert Allow lines into each Location block
        sed -i '/^<Location \/>/a\  Allow @LOCAL\n  Allow @IF(eth0)' "$CUPS_CONF" 2>/dev/null || true
    fi

    systemctl restart cups
    ok "CUPS restarted with network config"
}

# ── Print Test Page ────────────────────────────────────────────────────
print_test() {
    echo ""
    info "Step 8: Print a test page?"

    # Check for /dev/usb/lp0 before offering
    if [[ ! -c /dev/usb/lp0 ]]; then
        warn "No printer detected — skipping test page."
        warn "After connecting the printer, run: lp -d $QUEUE_NAME /path/to/label.pdf"
        return
    fi

    # Generate a simple test label with Python
    TEST_PDF="/tmp/sp420-test-label.pdf"
    python3 -c "
from PIL import Image, ImageDraw, ImageFont
import os

W, H = 1800, 1200  # 6x4 at ~300dpi for a clean PDF
img = Image.new('RGB', (W, H), 'white')
draw = ImageDraw.Draw(img)

# Large title
draw.text((60, 80), 'SP420 THERMAL PRINTER', fill='black')
draw.text((60, 180), 'Test Label', fill='black')

# Printer info
draw.text((60, 350), f'Date: $(date +%Y-%m-%d)', fill='black')
draw.text((60, 430), f'Queue: $QUEUE_NAME', fill='black')
draw.text((60, 510), 'iDPRT SP420 - 4x6 Label', fill='black')

# Box
draw.rectangle([30, 30, W-30, H-30], outline='black', width=8)
draw.line([W//2, 30, W//2, H-30], fill='black', width=4)
draw.line([30, H//2, W-30, H//2], fill='black', width=4)

img.save('$TEST_PDF')
" 2>/dev/null || {
        # Fallback: create simple test via text
        echo "SP420 Test Label - $(date)" > /tmp/test-label.txt
        python3 -c "
from PIL import Image, ImageDraw
img = Image.new('RGB', (1200, 800), 'white')
d = ImageDraw.Draw(img)
d.text((50,50), 'SP420 Test Page', fill='black')
d.text((50,150), 'If you see this, your printer works!', fill='black')
img.save('/tmp/sp420-test-label.pdf')
"
    }

    echo ""
    echo "  A test label has been generated."
    echo "  Print it with:"
    echo ""
    echo "    lp -d $QUEUE_NAME /tmp/sp420-test-label.pdf"
    echo ""
    echo "  Or run this now:"
    read -rp "  Print test label? [Y/n] " yn
    yn="${yn:-Y}"
    if [[ "$yn" =~ ^[Yy] ]]; then
        lp -d "$QUEUE_NAME" /tmp/sp420-test-label.pdf 2>&1 && ok "Test label sent!"
    fi
}

# ── Summary ────────────────────────────────────────────────────────────
print_summary() {
    # Get IP address for the summary
    PI_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | grep -v '127.0.0.1' | head -1)
    PI_HOST=$(hostname -f 2>/dev/null || hostname)

    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  ✅  SP420 Thermal Label Printer — Setup Complete      ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Printer queue:        $QUEUE_NAME"
    echo "  Printer location:     ipp://$PI_IP:631/printers/$QUEUE_NAME"
    echo "  mDNS name:            SP420 Thermal Label Printer 4x6"
    echo "  Config file:          $CONFIG_DEST"
    echo "  Backend:              $BACKEND_DEST"
    echo ""
    echo "  ── Add from any device ──"
    echo ""
    echo "  Linux/macOS:  Auto-discovers as 'SP420 Thermal Label Printer 4x6'"
    echo "  Android:      Install 'Mopria Print Service' from Play Store"
    echo "  Windows:      Add Printer → IPP → ipp://$PI_IP:631/printers/$QUEUE_NAME"
    echo "  Any OS:       ipp://$PI_HOST:631/printers/$QUEUE_NAME"
    echo ""
    echo "  ── Print a label ──"
    echo ""
    echo "  lp -d $QUEUE_NAME my-label.pdf"
    echo "  lp -d $QUEUE_NAME -n 5 my-label.pdf    (5 copies)"
    echo ""
    echo "  ── Troubleshooting ──"
    echo ""
    echo "  Check queue:  lpstat -p $QUEUE_NAME -l"
    echo "  Check jobs:   lpstat -o $QUEUE_NAME"
    echo "  View logs:    sudo journalctl -u cups -n 50 --no-pager"
    echo ""
}

# ── Main ───────────────────────────────────────────────────────────────
main() {
    preflight
    install_deps
    install_backend
    install_ppd
    install_config
    configure_cups_network
    create_queue
    install_avahi
    print_test
    print_summary
}

main "$@"
