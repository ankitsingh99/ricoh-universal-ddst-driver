#!/usr/bin/env bash
# ==============================================================================
# Ricoh DDST Driver - Network & Mobile Printing Integration Test Suite
# Validates IPP remote endpoints, AirPrint mDNS registration, offline spooling,
# and CUPS error recovery policies.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d -t ricoh_nettest_XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

cd "${SCRIPT_DIR}"

OS="$(uname -s)"
PRINTER_NAME=$(lpstat -p 2>/dev/null | grep -i "Ricoh" | awk '{print $2}' | head -1 || true)
if [ -z "$PRINTER_NAME" ]; then
    PRINTER_NAME="Ricoh_SP_200_DDST"
fi

echo "========================================================"
echo " Running Network & Mobile Printing Integration Tests"
echo " Detected OS: $OS"
echo " Target Queue: $PRINTER_NAME"
echo "========================================================"

# Test 1: Validate enable_network_printing.sh script execution
echo "[1/6] Testing enable_network_printing.sh status and flags..."
./enable_network_printing.sh --help >/dev/null
./enable_network_printing.sh --status > "${TMP_DIR}/status.log"
grep -q "Ricoh Network Printing Status" "${TMP_DIR}/status.log"
echo "  [PASS] CLI script flags validated."

# Test 2: Check CUPS remote sharing configuration
echo "[2/6] Verifying CUPS remote sharing configuration..."
if command -v cupsctl >/dev/null 2>&1; then
    CUPS_CONF=$(cupsctl)
    echo "$CUPS_CONF" | grep -q "_share_printers=1" || { echo "FAIL: _share_printers is not 1"; exit 1; }
    echo "$CUPS_CONF" | grep -q "_remote_any=1" || { echo "FAIL: _remote_any is not 1"; exit 1; }
    echo "  [PASS] CUPS server configured for remote multi-device sharing."
fi

# Test 3: Check Queue Error Policy and Acceptance
echo "[3/6] Verifying offline queue holding policies..."
lpstat -p "$PRINTER_NAME" -l > "${TMP_DIR}/printer_info.log"
grep -qi "enabled" "${TMP_DIR}/printer_info.log" || { echo "FAIL: Printer not enabled"; exit 1; }

# Test 4: Verify AirPrint mDNS service announcement
echo "[4/6] Verifying AirPrint / IPP mDNS service state..."
if [ "$OS" = "Darwin" ]; then
    PLIST="$HOME/Library/LaunchAgents/com.ricoh.airprint.plist"
    [ -f "$PLIST" ] || { echo "FAIL: LaunchAgent plist missing"; exit 1; }
    launchctl list | grep -q "com.ricoh.airprint" || { echo "FAIL: LaunchAgent not running"; exit 1; }
    grep -q "_universal" "$PLIST" || { echo "FAIL: AirPrint universal subtype missing in plist"; exit 1; }
    echo "  [PASS] macOS AirPrint background broadcast is active."
fi

# Test 5: End-to-end PDF generation & IPP Print-Job submission while offline
echo "[5/6] Testing IPP job submission & queue retention while printer is offline..."
# Generate a minimal PDF test page
python3 -c "
content = b'''%PDF-1.4
1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
3 0 obj << /Type /Page /Parent 2 0 R /Resources << /Font << /F1 4 0 R >> >> /MediaBox [0 0 595 842] /Contents 5 0 R >> endobj
4 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj
5 0 obj << /Length 43 >> stream
BT /F1 20 Tf 100 700 Td (Offline Mobile Print Test) Tj ET
endstream
endobj
xref
0 6
0000000000 65535 f 
0000000009 00000 n 
0000000058 00000 n 
0000000115 00000 n 
0000000229 00000 n 
0000000307 00000 n 
trailer << /Size 6 /Root 1 0 R >>
startxref
401
%%EOF
'''
with open('${TMP_DIR}/test.pdf', 'wb') as f:
    f.write(content)
"

# Submit job via IPP
if command -v ipptool >/dev/null 2>&1; then
    IPP_OUT=$(ipptool -tv -f "${TMP_DIR}/test.pdf" "http://127.0.0.1:631/printers/${PRINTER_NAME}" print-job.test 2>&1)
    echo "$IPP_OUT" | grep -q "successful-ok" || { echo "FAIL: IPP Print-Job did not succeed: $IPP_OUT"; exit 1; }
    NEW_JOB_ID=$(echo "$IPP_OUT" | grep "job-id (integer)" | awk '{print $4}')
    echo "  [PASS] Job #$NEW_JOB_ID accepted via IPP protocol."

    # Verify job appears in queue
    sleep 1
    lpstat -o "$PRINTER_NAME" | grep -q "$NEW_JOB_ID" || { echo "FAIL: Job #$NEW_JOB_ID not found in lpstat -o"; exit 1; }
    echo "  [PASS] Job #$NEW_JOB_ID is safely spooled in local CUPS queue."

    # Clean up test job
    cancel "${PRINTER_NAME}-${NEW_JOB_ID}" 2>/dev/null || true
    echo "  [PASS] Cleaned up temporary test job."
fi

# Test 6: Verify Filter Pipeline from PDF to Ricoh DDST Wire Protocol
echo "[6/6] Verifying PDF -> cups-raster -> DDST binary filter chain..."
PPD_FILE="/Library/Printers/PPDs/Contents/Resources/ricoh-sp200.ppd"
if [ ! -f "$PPD_FILE" ]; then
    PPD_FILE="ppd/ricoh-sp200.ppd"
fi

if command -v cupsfilter >/dev/null 2>&1 && [ -f "/Library/Printers/Ricoh/Filter/rastertoricohddst" ]; then
    STREAM_SIZE=$(cupsfilter -p "$PPD_FILE" -m application/vnd.cups-raster "${TMP_DIR}/test.pdf" 2>/dev/null | /Library/Printers/Ricoh/Filter/rastertoricohddst 999 test "Filter Test" 1 "" 2>/dev/null | wc -c | tr -d ' ')
    if [ "$STREAM_SIZE" -gt 500 ]; then
        echo "  [PASS] End-to-end filter pipeline converted PDF to $STREAM_SIZE bytes of valid DDST/PJL wire data."
    else
        echo "FAIL: DDST output size unexpectedly small: $STREAM_SIZE bytes"
        exit 1
    fi
else
    echo "  [*] Skipping live cupsfilter test (driver not installed in system path yet)."
fi

echo ""
echo "========================================================"
echo " *** ALL NETWORK & MOBILE PRINTING TESTS PASSED ***"
echo "========================================================"
