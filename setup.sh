#!/usr/bin/env bash
# ==============================================================================
# Ricoh Universal DDST/GDI CUPS Driver Suite - Universal Automated Installer
# Supports: Ricoh SP 100, SP 110, SP 111, SP 112, SP 150, SP 200, SP 210, SP 230, SP 310 Series
# Platforms: Linux (Debian, Ubuntu, Fedora, RHEL, openSUSE, Arch, Alpine, Void, Gentoo),
#            FreeBSD, OpenBSD, NetBSD, DragonFly BSD, macOS (Intel & Apple Silicon),
#            Solaris / illumos (OpenIndiana, OmniOS), and POSIX/Unix environments.
# ==============================================================================

set -euo pipefail

DEFAULT_PRINTER_NAME="Ricoh_SP_200_DDST"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS="$(uname -s)"
ARCH="$(uname -m)"

echo "========================================================"
echo "  Ricoh Universal DDST/GDI Driver Suite Installer"
echo "  Detected OS: $OS ($ARCH)"
echo "========================================================"

# Determine privilege escalation method (root, sudo, or doas)
ROOT_CMD=""
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        ROOT_CMD="sudo"
    elif command -v doas >/dev/null 2>&1; then
        ROOT_CMD="doas"
    else
        echo "Error: Superuser permissions required. Please run this installer as root (su) or install sudo/doas."
        exit 1
    fi
fi

run_root() {
    if [ -n "$ROOT_CMD" ]; then
        $ROOT_CMD "$@"
    else
        "$@"
    fi
}

require_elevated() {
    if [ "$(id -u)" -ne 0 ] && [ -n "$ROOT_CMD" ]; then
        echo ""
        echo "[*] Requesting superuser permissions for system installation..."
        if [ "$ROOT_CMD" = "sudo" ]; then
            sudo -v || { echo "Error: sudo authentication failed."; exit 1; }
        fi
    fi
}

# ------------------------------------------------------------------------------
# 1. Dependency Resolution & Package Manager Handling
# ------------------------------------------------------------------------------
echo ""
echo "[1/5] Checking and installing dependencies..."

case "$OS" in
    Darwin)
        if command -v brew >/dev/null 2>&1; then
            BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
            for pkg in cups jbigkit ghostscript; do
                if ! brew list --formula "$pkg" >/dev/null 2>&1; then
                    echo "Installing $pkg via Homebrew..."
                    brew install "$pkg"
                else
                    echo "  [OK] $pkg is installed"
                fi
            done
        elif command -v port >/dev/null 2>&1; then
            echo "Installing dependencies via MacPorts..."
            run_root port install cups jbigkit ghostscript
        else
            echo "Warning: Neither Homebrew nor MacPorts found. Assuming required libraries are in standard paths."
        fi
        ;;

    FreeBSD|DragonFly)
        require_elevated
        if command -v pkg >/dev/null 2>&1; then
            echo "Installing dependencies via FreeBSD pkg..."
            run_root pkg install -y cups jbigkit ghostscript gcc gmake
        else
            echo "Warning: 'pkg' command not found. Ensure cups, jbigkit, and ghostscript are installed."
        fi
        ;;

    OpenBSD)
        require_elevated
        if command -v pkg_add >/dev/null 2>&1; then
            echo "Installing dependencies via OpenBSD pkg_add..."
            run_root pkg_add cups jbigkit ghostscript || true
        else
            echo "Warning: 'pkg_add' not found. Ensure cups, jbigkit, and ghostscript are installed."
        fi
        ;;

    NetBSD)
        require_elevated
        if command -v pkgin >/dev/null 2>&1; then
            echo "Installing dependencies via NetBSD pkgin..."
            run_root pkgin -y install cups jbigkit ghostscript || true
        elif command -v pkg_add >/dev/null 2>&1; then
            run_root pkg_add cups jbigkit ghostscript || true
        fi
        ;;

    SunOS)
        require_elevated
        if command -v pkg >/dev/null 2>&1; then
            echo "Installing dependencies via IPS pkg..."
            run_root pkg install -q print/cups library/jbigkit print/filter/ghostscript || true
        elif command -v pkgutil >/dev/null 2>&1; then
            run_root pkgutil -y -i cups jbigkit ghostscript || true
        fi
        ;;

    Linux)
        if [ -f /etc/debian_version ]; then
            require_elevated
            echo "Updating package list and installing Debian/Ubuntu dependencies..."
            run_root apt-get update -qq
            run_root apt-get install -y libcups2-dev libcupsimage2-dev libjbig-dev jbigkit-bin gcc make ghostscript cups cups-client \
                || run_root apt-get install -y libcupsfilters-dev libcups2-dev libjbig-dev gcc make ghostscript cups cups-client
        elif [ -f /etc/fedora-release ] || [ -f /etc/redhat-release ]; then
            require_elevated
            echo "Installing Fedora/RHEL dependencies..."
            if command -v dnf >/dev/null 2>&1; then
                run_root dnf install -y cups-devel cups-libs jbigkit-devel jbigkit-libs gcc make ghostscript
            else
                run_root yum install -y cups-devel cups-libs jbigkit-devel jbigkit-libs gcc make ghostscript
            fi
        elif [ -f /etc/zypp/zypp.conf ] || [ -f /etc/SuSE-release ]; then
            require_elevated
            echo "Installing openSUSE dependencies via zypper..."
            run_root zypper install -y cups-devel libjbig-devel gcc make ghostscript cups-client
        elif [ -f /etc/arch-release ]; then
            require_elevated
            echo "Installing Arch Linux dependencies via pacman..."
            run_root pacman -S --needed --noconfirm cups ghostscript jbigkit gcc make
        elif [ -f /etc/alpine-release ]; then
            require_elevated
            echo "Installing Alpine Linux dependencies via apk..."
            run_root apk add --no-cache cups-dev cups-filters-dev jbigkit-dev gcc musl-dev make ghostscript cups-client
        elif [ -f /etc/void-release ] || command -v xbps-install >/dev/null 2>&1; then
            require_elevated
            echo "Installing Void Linux dependencies via xbps..."
            run_root xbps-install -Sy cups-devel jbigkit-devel gcc make ghostscript base-devel
        elif [ -f /etc/gentoo-release ]; then
            require_elevated
            echo "Installing Gentoo dependencies via emerge..."
            run_root emerge --ask=n net-print/cups media-libs/jbigkit app-text/ghostscript || true
        else
            echo "  [*] Generic or unrecognized Linux distribution."
            echo "      Verifying presence of C compiler and CUPS development headers..."
        fi
        ;;

    *)
        echo "  [*] Unix/POSIX environment: $OS"
        ;;
esac

# ------------------------------------------------------------------------------
# 2. CUPS Paths & Compiler Flag Detection
# ------------------------------------------------------------------------------
echo ""
echo "[2/5] Detecting CUPS paths and compiler flags..."

# Detect C compiler
if [ -n "${CC:-}" ] && command -v "$CC" >/dev/null 2>&1; then
    COMPILER="$CC"
elif command -v gcc >/dev/null 2>&1; then
    COMPILER="gcc"
elif command -v clang >/dev/null 2>&1; then
    COMPILER="clang"
elif command -v cc >/dev/null 2>&1; then
    COMPILER="cc"
else
    echo "Error: No suitable C compiler (gcc/clang/cc) found. Please install a C compiler."
    exit 1
fi
echo "  [OK] Using C compiler: $COMPILER ($("$COMPILER" --version 2>&1 | head -1))"

# Detect filter directory
FILTER_DIR=""
if [ "$OS" = "Darwin" ]; then
    FILTER_DIR="/Library/Printers/Ricoh/Filter"
elif command -v cups-config >/dev/null 2>&1; then
    FILTER_DIR="$(cups-config --serverbin 2>/dev/null)/filter"
elif [ -d "/usr/local/libexec/cups/filter" ]; then
    FILTER_DIR="/usr/local/libexec/cups/filter"
elif [ -d "/usr/pkg/libexec/cups/filter" ]; then
    FILTER_DIR="/usr/pkg/libexec/cups/filter"
elif [ -d "/usr/lib/cups/filter" ]; then
    FILTER_DIR="/usr/lib/cups/filter"
else
    FILTER_DIR="/usr/lib/cups/filter"
fi

# Detect PPD directory
PPD_DIR=""
if [ "$OS" = "Darwin" ]; then
    PPD_DIR="/Library/Printers/PPDs/Contents/Resources"
elif [ -d "/usr/share/ppd/cupsfilters" ]; then
    PPD_DIR="/usr/share/ppd/cupsfilters"
elif command -v cups-config >/dev/null 2>&1; then
    PPD_DIR="$(cups-config --datadir 2>/dev/null)/model"
elif [ -d "/usr/local/share/cups/model" ]; then
    PPD_DIR="/usr/local/share/cups/model"
elif [ -d "/usr/pkg/share/cups/model" ]; then
    PPD_DIR="/usr/pkg/share/cups/model"
else
    PPD_DIR="/usr/share/cups/model"
fi

echo "  [OK] Target Filter Directory: $FILTER_DIR"
echo "  [OK] Target PPD Directory:    $PPD_DIR"

# Build compiler flags
CFLAGS="-O2 -Wall -Wextra"
CPPFLAGS="-I/usr/local/include -I/usr/pkg/include -I/opt/homebrew/include"
LDFLAGS="-L/usr/local/lib -L/usr/pkg/lib -L/opt/homebrew/lib"

if command -v cups-config >/dev/null 2>&1; then
    CPPFLAGS="$CPPFLAGS $(cups-config --cflags 2>/dev/null || true)"
    CUPS_LIBS="$(cups-config --libs 2>/dev/null || echo -lcups)"
else
    CUPS_LIBS="-lcups"
fi
LIBS="$CUPS_LIBS -lcupsimage -ljbig"

# ------------------------------------------------------------------------------
# 3. Compile Filters
# ------------------------------------------------------------------------------
echo ""
echo "[3/5] Compiling universal driver binaries..."
cd "$SCRIPT_DIR"

# shellcheck disable=SC2086
$COMPILER $CFLAGS $CPPFLAGS $LDFLAGS -o rastertoricohddst rastertoricohddst.c $LIBS
# shellcheck disable=SC2086
$COMPILER $CFLAGS $CPPFLAGS $LDFLAGS -o rastertoricohjbig rastertoricohjbig.c $LIBS

echo "  [OK] Compiled rastertoricohddst"
echo "  [OK] Compiled rastertoricohjbig"

# ------------------------------------------------------------------------------
# 4. Install Filter Binaries and PPD Library
# ------------------------------------------------------------------------------
echo ""
echo "[4/5] Installing driver binaries and PPD library..."
require_elevated

run_root mkdir -p "$FILTER_DIR" "$PPD_DIR"
run_root install -m 755 rastertoricohddst "$FILTER_DIR/rastertoricohddst"
run_root install -m 755 rastertoricohjbig "$FILTER_DIR/rastertoricohjbig"

if [ "$OS" = "Darwin" ]; then
    for ppd in "$SCRIPT_DIR"/ppd/*.ppd "$SCRIPT_DIR"/ricoh-sp200.ppd; do
        if [ -f "$ppd" ]; then
            target="$PPD_DIR/$(basename "$ppd")"
            sed "s|application/vnd.cups-raster 0 rastertoricohddst|application/vnd.cups-raster 0 $FILTER_DIR/rastertoricohddst|g; s|application/vnd.cups-raster 0 rastertoricohjbig|application/vnd.cups-raster 0 $FILTER_DIR/rastertoricohjbig|g" "$ppd" | run_root tee "$target" >/dev/null
            run_root chmod 644 "$target"
        fi
    done
    run_root chown -R root:wheel /Library/Printers/Ricoh 2>/dev/null || true
    run_root chown root:wheel "$PPD_DIR"/ricoh-sp*.ppd 2>/dev/null || true
    run_root xattr -d com.apple.quarantine "$FILTER_DIR/rastertoricohddst" "$FILTER_DIR/rastertoricohjbig" 2>/dev/null || true
else
    for ppd in "$SCRIPT_DIR"/ppd/*.ppd "$SCRIPT_DIR"/ricoh-sp200.ppd; do
        if [ -f "$ppd" ]; then
            run_root install -m 644 "$ppd" "$PPD_DIR/"
        fi
    done
fi

echo "  [OK] Filter binaries installed in: $FILTER_DIR"
echo "  [OK] PPD library installed in:    $PPD_DIR"

# Ensure CUPS daemon is running
if ! lpstat -r >/dev/null 2>&1; then
    echo "  [*] CUPS daemon not running. Attempting to start cupsd service..."
    if [ "$OS" = "Darwin" ]; then
        run_root launchctl kickstart -k system/org.cups.cupsd 2>/dev/null || true
    elif command -v systemctl >/dev/null 2>&1; then
        run_root systemctl start cups 2>/dev/null || run_root systemctl start cupsd 2>/dev/null || true
    elif command -v rc-service >/dev/null 2>&1; then
        run_root rc-service cupsd start 2>/dev/null || run_root rc-service cups start 2>/dev/null || true
    elif command -v service >/dev/null 2>&1; then
        run_root service cupsd start 2>/dev/null || run_root service cups start 2>/dev/null || true
    elif command -v rcctl >/dev/null 2>&1; then
        run_root rcctl start cupsd 2>/dev/null || true
    fi
    sleep 1
fi

# ------------------------------------------------------------------------------
# 5. Printer Discovery & Registration
# ------------------------------------------------------------------------------
echo ""
echo "[5/5] Detecting connected Ricoh laser printer..."

DEVICE_URI=""

# Try CUPS USB backend executable directly if available
USB_BACKEND=""
if command -v cups-config >/dev/null 2>&1; then
    candidate="$(cups-config --serverbin 2>/dev/null)/backend/usb"
    [ -x "$candidate" ] && USB_BACKEND="$candidate"
fi
for candidate in /usr/libexec/cups/backend/usb /usr/local/libexec/cups/backend/usb /usr/pkg/libexec/cups/backend/usb /usr/lib/cups/backend/usb; do
    if [ -z "$USB_BACKEND" ] && [ -x "$candidate" ]; then
        USB_BACKEND="$candidate"
        break
    fi
done

if [ -n "$USB_BACKEND" ]; then
    DEVICE_URI=$("$USB_BACKEND" 2>/dev/null | grep -i "ricoh" | awk '{print $2}' | head -1 || true)
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
run_root lpadmin -x "$PRINTER_NAME" 2>/dev/null || true
run_root lpadmin -p "$PRINTER_NAME" -v "$DEVICE_URI" -P "$SELECTED_PPD" -E
run_root lpadmin -p "$PRINTER_NAME" -o printer-is-shared=true -o printer-error-policy=retry-current-job 2>/dev/null || true
run_root cupsenable "$PRINTER_NAME" 2>/dev/null || true
run_root cupsaccept "$PRINTER_NAME" 2>/dev/null || true

echo "  [OK] Printer '$PRINTER_NAME' registered, shared, and enabled."

# Check printer queue status
lpstat -p "$PRINTER_NAME" -l 2>/dev/null || true

echo ""
echo "========================================================"
echo "  INSTALLATION COMPLETE"
echo "========================================================"
echo "  Queue Name:   $PRINTER_NAME"
echo "  Active PPD:   $SELECTED_PPD"
echo "  Available PPDs installed in CUPS library:"
find "$PPD_DIR" -maxdepth 1 -name "ricoh-sp*.ppd" 2>/dev/null || ls -1 "$PPD_DIR"/ricoh-sp*.ppd 2>/dev/null || true
echo ""
echo "  To send a test page:"
echo "    echo 'Hello from Ricoh Driver Suite' | lpr -P $PRINTER_NAME"
echo "  or run:"
echo "    ./test_print.sh"
echo ""
echo "  To enable Mobile & AirPrint Network Printing (iOS & Android):"
echo "    ./enable_network_printing.sh"
echo "========================================================"
