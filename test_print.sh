#!/usr/bin/env bash
# ==============================================================================
# Ricoh DDST Driver Suite - Test Print Script
# Compatible with Linux, FreeBSD, OpenBSD, NetBSD, macOS, and Unix
# ==============================================================================

set -euo pipefail

PRINTER_NAME="${1:-}"

if [ -z "$PRINTER_NAME" ]; then
    # Automatically detect any registered Ricoh queue from CUPS
    PRINTER_NAME=$(lpstat -p 2>/dev/null | grep -i "Ricoh" | awk '{print $2}' | head -1 || true)
fi

if [ -z "$PRINTER_NAME" ]; then
    PRINTER_NAME="Ricoh_SP_200_DDST"
fi

echo "Target printer queue: '$PRINTER_NAME'"
echo "Checking printer '$PRINTER_NAME' status..."
lpstat -p "$PRINTER_NAME" -l 2>/dev/null || echo "Warning: Printer queue '$PRINTER_NAME' not found or CUPS not running."

echo ""
echo "Sending single test print page to '$PRINTER_NAME'..."

{
  echo "=================================================="
  echo "      Ricoh Universal DDST Driver Test Page       "
  echo "=================================================="
  echo ""
  echo "  Timestamp : $(date)"
  echo "  Platform  : $(uname -s) ($(uname -m))"
  echo "  Printer   : $PRINTER_NAME"
  echo "  Driver    : Native Universal DDST CUPS Filter"
  echo ""
  echo "  If you can read this, your Ricoh DDST driver"
  echo "  is functioning properly on your system."
  echo ""
  echo "=================================================="
} | lpr -P "$PRINTER_NAME"

echo "[OK] Print job submitted. Checking queue..."
sleep 1
lpstat -o "$PRINTER_NAME" 2>/dev/null || lpstat -o 2>/dev/null || true
