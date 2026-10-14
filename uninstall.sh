#!/usr/bin/env bash
# ==============================================================================
# Ricoh DDST Driver Suite - Universal Uninstaller Script
# Compatible with Linux, FreeBSD, OpenBSD, NetBSD, macOS, and Solaris/Unix
# ==============================================================================

set -euo pipefail

TARGET_PRINTER="${1:-Ricoh_SP_200_DDST}"
OS="$(uname -s)"

echo "========================================================"
echo "  Ricoh Universal DDST/GDI Driver Suite Uninstaller"
echo "  Detected OS: $OS"
echo "========================================================"

ROOT_CMD=""
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        ROOT_CMD="sudo"
    elif command -v doas >/dev/null 2>&1; then
        ROOT_CMD="doas"
    else
        echo "Error: Superuser permissions required. Please run as root (su) or install sudo/doas."
        exit 1
    fi
    echo "[*] Requesting superuser permissions..."
    if [ "$ROOT_CMD" = "sudo" ]; then
        sudo -v || { echo "Error: sudo authentication failed."; exit 1; }
    fi
fi

run_root() {
    if [ -n "$ROOT_CMD" ]; then
        $ROOT_CMD "$@"
    else
        "$@"
    fi
}

# 1. Remove CUPS Printer Queues
echo "[1/3] Removing CUPS printer queue(s)..."
for q in "$TARGET_PRINTER" \
         Ricoh_SP_100_DDST Ricoh_SP_111_DDST Ricoh_SP_150_DDST \
         Ricoh_SP_200_DDST Ricoh_SP_210_DDST Ricoh_SP_230_DDST \
         Ricoh_SP_310_DDST; do
    if lpstat -p "$q" >/dev/null 2>&1; then
        run_root lpadmin -x "$q" 2>/dev/null || true
        echo "  [OK] Removed CUPS queue '$q'"
    fi
done

# 2. Remove Filter Binaries
echo "[2/3] Removing filter binaries..."
FILTER_PATHS=(
    "/Library/Printers/Ricoh/Filter/rastertoricohddst"
    "/Library/Printers/Ricoh/Filter/rastertoricohjbig"
    "/usr/lib/cups/filter/rastertoricohddst"
    "/usr/lib/cups/filter/rastertoricohjbig"
    "/usr/local/libexec/cups/filter/rastertoricohddst"
    "/usr/local/libexec/cups/filter/rastertoricohjbig"
    "/usr/pkg/libexec/cups/filter/rastertoricohddst"
    "/usr/pkg/libexec/cups/filter/rastertoricohjbig"
)

if command -v cups-config >/dev/null 2>&1; then
    SERVER_BIN="$(cups-config --serverbin 2>/dev/null || true)"
    if [ -n "$SERVER_BIN" ]; then
        FILTER_PATHS+=("$SERVER_BIN/filter/rastertoricohddst" "$SERVER_BIN/filter/rastertoricohjbig")
    fi
fi

for bin in "${FILTER_PATHS[@]}"; do
    if [ -f "$bin" ]; then
        run_root rm -f "$bin"
        echo "  [OK] Removed filter: $bin"
    fi
done

# 3. Remove PPD Library
echo "[3/3] Removing PPD profiles..."
PPD_DIRS=(
    "/Library/Printers/PPDs/Contents/Resources"
    "/usr/share/ppd/cupsfilters"
    "/usr/share/cups/model"
    "/usr/local/share/cups/model"
    "/usr/pkg/share/cups/model"
)

if command -v cups-config >/dev/null 2>&1; then
    DATA_DIR="$(cups-config --datadir 2>/dev/null || true)"
    if [ -n "$DATA_DIR" ]; then
        PPD_DIRS+=("$DATA_DIR/model")
    fi
fi

for pdir in "${PPD_DIRS[@]}"; do
    if [ -d "$pdir" ]; then
        MATCHES=$(find "$pdir" -maxdepth 1 -name "ricoh-sp*.ppd" 2>/dev/null || true)
        if [ -n "$MATCHES" ]; then
            for ppd in $MATCHES; do
                run_root rm -f "$ppd"
                echo "  [OK] Removed PPD: $ppd"
            done
        fi
    fi
done

if [ "$OS" = "Darwin" ]; then
    run_root rm -rf /Library/Printers/Ricoh 2>/dev/null || true
fi

echo ""
echo "========================================================"
echo "  UNINSTALLATION COMPLETE"
echo "  Ricoh driver suite and queues removed cleanly."
echo "========================================================"
