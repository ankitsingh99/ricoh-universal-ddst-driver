#!/bin/bash
# ==============================================================================
# Ricoh Universal DDST/GDI CUPS Driver Suite - Automated Installer
# Supports: Ricoh SP 100, SP 110, SP 150, SP 200, SP 210, SP 230, SP 310 Series
# Platforms: macOS (Apple Silicon & Intel) and Linux (Debian/Ubuntu/Fedora/Arch)
# ==============================================================================

set -euo pipefail

DEFAULT_PRINTER_NAME="Ricoh_SP_200_DDST"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS="$(uname -s)"

echo "========================================================"
echo "  Ricoh Universal DDST/GDI Driver Suite Installer"
echo "  Detected OS: $OS ($(uname -m))"
echo "========================================================"

require_sudo() {
    if [ "$EUID" -ne 0 ]; then
        echo ""
        echo "[*] Superuser permissions required for system installation."
        sudo -v || { echo "Error: sudo required to install printer driver."; exit 1; }
    fi
}

# ------------------------------------------------------------------------------
# 1. Dependency Resolution
# ------------------------------------------------------------------------------
echo ""
echo "[1/5] Checking and installing dependencies..."

if [ "$OS" = "Darwin" ]; then
    if ! command -v brew >/dev/null 2>&1; then
        echo "Error: Homebrew is not installed. Please install Homebrew from https://brew.sh/"
        exit 1
    fi

    BREW_PREFIX="$(brew --prefix)"
    for pkg in cups jbigkit ghostscript; do
        if ! brew list --formula "$pkg" >/dev/null 2>&1; then
            echo "Installing $pkg via Homebrew..."
            brew install "$pkg"
        else
            echo "  [OK] $pkg is installed"
        fi
    done

    FILTER_DIR="/Library/Printers/Ricoh/Filter"
    PPD_DIR="/Library/Printers/PPDs/Contents/Resources"
    CFLAGS="-O2 -Wall -Wextra -I${BREW_PREFIX}/include"
    LIBS="-L${BREW_PREFIX}/lib -lcups -lcupsimage -ljbig"

elif [ -f /etc/debian_version ]; then
    require_sudo
    echo "Updating packages and installing build dependencies..."
    sudo apt-get update
    sudo apt-get install -y libcups2-dev libcupsimage2-dev libjbig-dev jbigkit-bin gcc ghostscript cups cups-client
    
    FILTER_DIR="/usr/lib/cups/filter"
    PPD_DIR="/usr/share/ppd/cupsfilters"
    CFLAGS="-O2 -Wall -Wextra"
    LIBS="$(cups-config --libs 2>/dev/null || echo -lcups) -lcupsimage -ljbig"

elif [ -f /etc/fedora-release ] || [ -f /etc/redhat-release ]; then
    require_sudo
    sudo dnf install -y cups-devel cups-libs jbigkit-devel jbigkit-libs gcc ghostscript
    
    FILTER_DIR="/usr/lib/cups/filter"
    PPD_DIR="/usr/share/ppd/cupsfilters"
    CFLAGS="-O2 -Wall -Wextra"
    LIBS="$(cups-config --libs 2>/dev/null || echo -lcups) -lcupsimage -ljbig"

elif [ -f /etc/arch-release ]; then
    require_sudo
    sudo pacman -S --needed --noconfirm cups ghostscript jbigkit gcc
    
    FILTER_DIR="/usr/lib/cups/filter"
    PPD_DIR="/usr/share/ppd/cupsfilters"
    CFLAGS="-O2 -Wall -Wextra"
    LIBS="$(cups-config --libs 2>/dev/null || echo -lcups) -lcupsimage -ljbig"
else
    FILTER_DIR="/usr/lib/cups/filter"
    PPD_DIR="/usr/share/ppd/cupsfilters"
    CFLAGS="-O2 -Wall -Wextra"
    LIBS="$(cups-config --libs 2>/dev/null || echo -lcups) -lcupsimage -ljbig"
fi

# ------------------------------------------------------------------------------
# 2. Compile Filters
# ------------------------------------------------------------------------------
echo ""
echo "[2/5] Compiling universal driver binaries..."
cd "$SCRIPT_DIR"

gcc $CFLAGS -o rastertoricohddst rastertoricohddst.c $LIBS
gcc $CFLAGS -o rastertoricohjbig rastertoricohjbig.c $LIBS
echo "  [OK] Compiled rastertoricohddst"
echo "  [OK] Compiled rastertoricohjbig"

# ------------------------------------------------------------------------------
# 3. Install Filter Binaries and PPD Library
# ------------------------------------------------------------------------------
echo ""
echo "[3/5] Installing driver binaries and PPD library..."
require_sudo

sudo mkdir -p "$FILTER_DIR" "$PPD_DIR"
sudo install -m 755 rastertoricohddst "$FILTER_DIR/rastertoricohddst"
sudo install -m 755 rastertoricohjbig "$FILTER_DIR/rastertoricohjbig"

if [ "$OS" = "Darwin" ]; then
    for ppd in "$SCRIPT_DIR"/ppd/*.ppd "$SCRIPT_DIR"/ricoh-sp200.ppd; do
        if [ -f "$ppd" ]; then
            target="$PPD_DIR/$(basename "$ppd")"
            sed 's|application/vnd.cups-raster 0 rastertoricohddst|application/vnd.cups-raster 0 /Library/Printers/Ricoh/Filter/rastertoricohddst|g; s|application/vnd.cups-raster 0 rastertoricohjbig|application/vnd.cups-raster 0 /Library/Printers/Ricoh/Filter/rastertoricohjbig|g' "$ppd" | sudo tee "$target" >/dev/null
            sudo chmod 644 "$target"
        fi
    done
    sudo chown -R root:wheel /Library/Printers/Ricoh
    sudo chown root:wheel "$PPD_DIR"/ricoh-sp*.ppd 2>/dev/null || true
    sudo xattr -d com.apple.quarantine "$FILTER_DIR/rastertoricohddst" "$FILTER_DIR/rastertoricohjbig" 2>/dev/null || true
else
    sudo install -m 644 "$SCRIPT_DIR"/ppd/*.ppd "$PPD_DIR/"
    sudo install -m 644 "$SCRIPT_DIR"/ricoh-sp200.ppd "$PPD_DIR/"
fi

echo "  [OK] Filter binaries installed in: $FILTER_DIR"
echo "  [OK] PPD library installed in:    $PPD_DIR"

# ------------------------------------------------------------------------------
# 4. Printer Discovery & Registration
# ------------------------------------------------------------------------------
echo ""
echo "[4/5] Detecting connected Ricoh laser printer..."

DEVICE_URI=""
if [ "$OS" = "Darwin" ]; then
    DEVICE_URI=$(/usr/libexec/cups/backend/usb 2>/dev/null | grep -i "ricoh" | awk '{print $2}' | head -1 || true)
fi

if [ -z "$DEVICE_URI" ]; then
    DEVICE_URI=$(lpinfo -v 2>/dev/null | grep -i "ricoh" | awk '{print $2}' | head -1 || true)
fi

if [ -z "$DEVICE_URI" ]; then
    DEVICE_URI=$(lpinfo -v 2>/dev/null | grep -i "usb:" | awk '{print $2}' | head -1 || true)
fi

SELECTED_PPD="$PPD_DIR/ricoh-sp200.ppd"
PRINTER_NAME="$DEFAULT_PRINTER_NAME"

if [ -n "$DEVICE_URI" ]; then
    echo "  [OK] Detected printer device URI: $DEVICE_URI"
    if echo "$DEVICE_URI" | grep -qi "SP%20100\|SP100"; then
        SELECTED_PPD="$PPD_DIR/ricoh-sp100.ppd"; PRINTER_NAME="Ricoh_SP_100_DDST"
    elif echo "$DEVICE_URI" | grep -qi "SP%20111\|SP111\|SP112"; then
        SELECTED_PPD="$PPD_DIR/ricoh-sp111.ppd"; PRINTER_NAME="Ricoh_SP_111_DDST"
    elif echo "$DEVICE_URI" | grep -qi "SP%20150\|SP150"; then
        SELECTED_PPD="$PPD_DIR/ricoh-sp150.ppd"; PRINTER_NAME="Ricoh_SP_150_DDST"
    elif echo "$DEVICE_URI" | grep -qi "SP%20210\|SP210\|SP211\|SP212"; then
        SELECTED_PPD="$PPD_DIR/ricoh-sp210.ppd"; PRINTER_NAME="Ricoh_SP_210_DDST"
    elif echo "$DEVICE_URI" | grep -qi "SP%20230\|SP230"; then
        SELECTED_PPD="$PPD_DIR/ricoh-sp230.ppd"; PRINTER_NAME="Ricoh_SP_230_DDST"
    elif echo "$DEVICE_URI" | grep -qi "SP%20310\|SP310\|SP311\|SP325\|SP3710"; then
        SELECTED_PPD="$PPD_DIR/ricoh-sp310.ppd"; PRINTER_NAME="Ricoh_SP_310_DDST"
    fi
else
    echo "  [*] Note: Printer not detected on USB right now."
    echo "      Using default placeholder URI: usb://RICOH/SP%20200%20DDST"
    DEVICE_URI="usb://RICOH/SP%20200%20DDST"
fi

echo "Registering printer queue '$PRINTER_NAME' with PPD: $(basename "$SELECTED_PPD")..."
sudo lpadmin -x "$PRINTER_NAME" 2>/dev/null || true
sudo lpadmin -p "$PRINTER_NAME" -v "$DEVICE_URI" -P "$SELECTED_PPD" -E
sudo lpadmin -p "$PRINTER_NAME" -o printer-is-shared=true -o printer-error-policy=retry-current-job 2>/dev/null || true
sudo cupsenable "$PRINTER_NAME" 2>/dev/null || true
sudo cupsaccept "$PRINTER_NAME" 2>/dev/null || true

echo "  [OK] Printer '$PRINTER_NAME' registered, shared, and enabled."

# ------------------------------------------------------------------------------
# 5. Status & Completion
# ------------------------------------------------------------------------------
echo ""
echo "[5/5] Checking printer queue status..."
lpstat -p "$PRINTER_NAME" -l 2>/dev/null || true

echo ""
echo "========================================================"
echo "  INSTALLATION COMPLETE"
echo "========================================================"
echo "  Queue Name:   $PRINTER_NAME"
echo "  Active PPD:   $SELECTED_PPD"
echo "  Available PPDs installed in CUPS library:"
ls -1 "$PPD_DIR"/ricoh-sp*.ppd 2>/dev/null || true
echo ""
echo "  To send a test page:"
echo "    echo 'Hello from Ricoh Driver Suite' | lpr -P $PRINTER_NAME"
echo "  or run:"
echo "    ./test_print.sh"
echo ""
echo "  To enable Mobile & AirPrint Network Printing (iOS & Android):"
echo "    ./enable_network_printing.sh"
echo "========================================================"
