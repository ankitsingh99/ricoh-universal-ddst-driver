#!/usr/bin/env bash
# ==============================================================================
# Ricoh Universal DDST/GDI Driver Suite - Auto Printer Model Detection Utility
# Inspects USB buses, IEEE 1284 Device IDs, and CUPS discovery backends to
# identify connected Ricoh laser printer models and select matching protocols.
#
# Protocols:
#   - DDST (JBIG stream framing): SP 100, SP 110/111/112, SP 200, SP 210, SP 230, SP 310
#   - LHPL (Command frame @sj/@sp/@ep): SP 150, SP 150SU, SP 150w, SP 150SUw
#
# SPDX-License-Identifier: MIT
# ==============================================================================

set -euo pipefail

MODE="human"
if [ "${1:-}" = "--json" ]; then
    MODE="json"
elif [ "${1:-}" = "--quiet" ] || [ "${1:-}" = "-q" ]; then
    MODE="quiet"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS="$(uname -s)"

# Temporary discovery accumulator
DETECTED_URI=""
DETECTED_MODEL=""
DETECTED_PROTOCOL=""
DETECTED_PPD=""
DETECTED_QUEUE=""
DETECTED_FILTER=""
DETECTED_SOURCE=""

# ------------------------------------------------------------------------------
# Discovery Layer 1: Query CUPS USB Backend directly for IEEE 1284 Device ID
# ------------------------------------------------------------------------------
query_cups_backend() {
    local backend=""
    for b in "/usr/libexec/cups/backend/usb" \
             "/usr/lib/cups/backend/usb" \
             "/usr/local/libexec/cups/backend/usb" \
             "/usr/pkg/libexec/cups/backend/usb"; do
        if [ -x "$b" ]; then
            backend="$b"
            break
        fi
    done

    if [ -n "$backend" ]; then
        local out
        out=$("$backend" 2>/dev/null || true)
        if echo "$out" | grep -qi "ricoh"; then
            DETECTED_URI=$(echo "$out" | grep -i "ricoh" | head -n 1 | awk '{print $2}')
            DETECTED_SOURCE="CUPS USB Backend ($backend)"
            return 0
        fi
    fi
    return 1
}

# ------------------------------------------------------------------------------
# Discovery Layer 2: macOS IORegistry USB scan (Instantaneous)
# ------------------------------------------------------------------------------
query_macos_usb() {
    if [ "$OS" = "Darwin" ] && command -v ioreg >/dev/null 2>&1; then
        local ioreg_out
        ioreg_out=$(ioreg -p IOUSB -l -w 0 2>/dev/null || true)
        # Ricoh USB Vendor ID is 1482 (0x05ca)
        if echo "$ioreg_out" | grep -qi "1482\|0x05ca\|ricoh"; then
            local model_match
            model_match=$(echo "$ioreg_out" | grep -i -E "\"USB Product Name\" = \"(Ricoh )?SP[ -]?[0-9]{3}[A-Za-z]*\"" | head -n 1 | sed -E 's/.*"USB Product Name" = "(.*)"/\1/' || true)
            if [ -n "$model_match" ]; then
                DETECTED_URI="usb://RICOH/$(echo "$model_match" | sed 's/ /%20/g')"
                DETECTED_SOURCE="macOS IOKit USB Registry"
                return 0
            fi
        fi
    fi
    return 1
}

# ------------------------------------------------------------------------------
# Discovery Layer 3: Linux /sys/bus/usb scanning
# ------------------------------------------------------------------------------
query_linux_sysfs() {
    if [ "$OS" = "Linux" ] && [ -d "/sys/bus/usb/devices" ]; then
        for dev in /sys/bus/usb/devices/*; do
            if [ -f "$dev/idVendor" ] && [ -f "$dev/product" ]; then
                local vid
                vid=$(cat "$dev/idVendor" 2>/dev/null || true)
                local prod
                prod=$(cat "$dev/product" 2>/dev/null || true)
                if [ "$vid" = "05ca" ] || echo "$prod" | grep -qi "ricoh"; then
                    DETECTED_URI="usb://RICOH/$(echo "$prod" | sed 's/ /%20/g')"
                    DETECTED_SOURCE="Linux sysfs /sys/bus/usb"
                    return 0
                fi
            fi
        done
    fi
    return 1
}

# ------------------------------------------------------------------------------
# Discovery Layer 4: lpinfo USB fallback (with 2s timeout guard)
# ------------------------------------------------------------------------------
query_lpinfo() {
    if command -v lpinfo >/dev/null 2>&1; then
        local out=""
        if command -v perl >/dev/null 2>&1; then
            out=$(perl -e 'alarm 2; exec @ARGV' lpinfo -v 2>/dev/null | grep -i "usb://RICOH" | head -n 1 || true)
        elif command -v timeout >/dev/null 2>&1; then
            out=$(timeout 2 lpinfo -v 2>/dev/null | grep -i "usb://RICOH" | head -n 1 || true)
        fi
        if [ -n "$out" ]; then
            DETECTED_URI=$(echo "$out" | awk '{print $2}')
            DETECTED_SOURCE="CUPS lpinfo discovery"
            return 0
        fi
    fi
    return 1
}

# ------------------------------------------------------------------------------
# Model Classification & Protocol Mapping Engine
# ------------------------------------------------------------------------------
classify_model() {
    local uri="${1:-}"

    if echo "$uri" | grep -qi "SP%20150\|SP150\|SP-150"; then
        DETECTED_MODEL="Ricoh SP 150 Series"
        DETECTED_PROTOCOL="LHPL"
        DETECTED_FILTER="rastertoricohlhpl"
        DETECTED_PPD="ppd/ricoh-sp150.ppd"
        DETECTED_QUEUE="Ricoh_SP_150_LHPL"
    elif echo "$uri" | grep -qi "SP%20100\|SP100\|SP-100"; then
        DETECTED_MODEL="Ricoh SP 100 Series"
        DETECTED_PROTOCOL="DDST"
        DETECTED_FILTER="rastertoricohddst"
        DETECTED_PPD="ppd/ricoh-sp100.ppd"
        DETECTED_QUEUE="Ricoh_SP_100_DDST"
    elif echo "$uri" | grep -qi "SP%20111\|SP111\|SP112\|SP%20110"; then
        DETECTED_MODEL="Ricoh SP 110/111 Series"
        DETECTED_PROTOCOL="DDST"
        DETECTED_FILTER="rastertoricohddst"
        DETECTED_PPD="ppd/ricoh-sp111.ppd"
        DETECTED_QUEUE="Ricoh_SP_111_DDST"
    elif echo "$uri" | grep -qi "SP%20210\|SP210\|SP211\|SP212\|SP213\|SP220"; then
        DETECTED_MODEL="Ricoh SP 210 Series"
        DETECTED_PROTOCOL="DDST"
        DETECTED_FILTER="rastertoricohddst"
        DETECTED_PPD="ppd/ricoh-sp210.ppd"
        DETECTED_QUEUE="Ricoh_SP_210_DDST"
    elif echo "$uri" | grep -qi "SP%20230\|SP230"; then
        DETECTED_MODEL="Ricoh SP 230 Series"
        DETECTED_PROTOCOL="DDST"
        DETECTED_FILTER="rastertoricohddst"
        DETECTED_PPD="ppd/ricoh-sp230.ppd"
        DETECTED_QUEUE="Ricoh_SP_230_DDST"
    elif echo "$uri" | grep -qi "SP%20310\|SP310\|SP311\|SP325\|SP3710"; then
        DETECTED_MODEL="Ricoh SP 310/325/3710 Series"
        DETECTED_PROTOCOL="DDST"
        DETECTED_FILTER="rastertoricohddst"
        DETECTED_PPD="ppd/ricoh-sp310.ppd"
        DETECTED_QUEUE="Ricoh_SP_310_DDST"
    elif echo "$uri" | grep -qi "SP%20200\|SP200\|SP201\|SP202\|SP204"; then
        DETECTED_MODEL="Ricoh SP 200 Series"
        DETECTED_PROTOCOL="DDST"
        DETECTED_FILTER="rastertoricohddst"
        DETECTED_PPD="ppd/ricoh-sp200.ppd"
        DETECTED_QUEUE="Ricoh_SP_200_DDST"
    elif [ -n "$uri" ]; then
        DETECTED_MODEL="Ricoh Laser Printer (Generic DDST)"
        DETECTED_PROTOCOL="DDST"
        DETECTED_FILTER="rastertoricohddst"
        DETECTED_PPD="ppd/ricoh-sp200.ppd"
        DETECTED_QUEUE="Ricoh_SP_200_DDST"
    fi
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    query_cups_backend || query_macos_usb || query_linux_sysfs || query_lpinfo || true
    if [ -n "$DETECTED_URI" ]; then
        classify_model "$DETECTED_URI"
    fi
fi

# ------------------------------------------------------------------------------
# Output Presentation
# ------------------------------------------------------------------------------
if [ "$MODE" = "json" ]; then
    if [ -n "$DETECTED_MODEL" ]; then
        cat << EOF
{
  "status": "detected",
  "model": "$DETECTED_MODEL",
  "protocol": "$DETECTED_PROTOCOL",
  "filter": "$DETECTED_FILTER",
  "ppd": "$DETECTED_PPD",
  "queue": "$DETECTED_QUEUE",
  "device_uri": "$DETECTED_URI",
  "discovery_source": "$DETECTED_SOURCE"
}
EOF
    else
        cat << 'EOF'
{
  "status": "not_detected",
  "message": "No active Ricoh USB or network printer currently detected."
}
EOF
    fi
elif [ "$MODE" = "quiet" ]; then
    if [ -n "$DETECTED_MODEL" ]; then
        echo "$DETECTED_MODEL|$DETECTED_PROTOCOL|$DETECTED_PPD|$DETECTED_QUEUE|$DETECTED_URI"
    else
        echo "NONE"
    fi
else
    echo "=================================================================="
    echo " Ricoh Universal Driver: Auto Printer Model Detection"
    echo " Operating System: $OS ($(uname -m))"
    echo "=================================================================="
    if [ -n "$DETECTED_MODEL" ]; then
        echo "  Status:           CONNECTED & DETECTED"
        echo "  Printer Model:    $DETECTED_MODEL"
        echo "  Protocol Family:  $DETECTED_PROTOCOL"
        echo "  CUPS Filter:      $DETECTED_FILTER"
        echo "  Recommended PPD:  $DETECTED_PPD"
        echo "  Queue Name:       $DETECTED_QUEUE"
        echo "  Device URI:       $DETECTED_URI"
        echo "  Discovery Source: $DETECTED_SOURCE"
        echo "=================================================================="
        echo "To register this printer queue automatically, run:"
        echo "  sudo ./setup.sh"
    else
        echo "  Status:           NO ACTIVE PRINTER DETECTED"
        echo ""
        echo "  No physical Ricoh printer is currently detected on USB."
        echo "  Plug in your Ricoh printer via USB and power it on, or configure"
        echo "  a network socket queue manually (e.g. socket://<ip>:9100)."
        echo ""
        echo "  Supported Model Families:"
        echo "    • Ricoh SP 100 Series       (DDST Protocol  -> rastertoricohddst)"
        echo "    • Ricoh SP 110/111 Series   (DDST Protocol  -> rastertoricohddst)"
        echo "    • Ricoh SP 150/150SU Series (LHPL Protocol  -> rastertoricohlhpl)"
        echo "    • Ricoh SP 200 Series       (DDST Protocol  -> rastertoricohddst)"
        echo "    • Ricoh SP 210/220 Series   (DDST Protocol  -> rastertoricohddst)"
        echo "    • Ricoh SP 230 Series       (DDST Protocol  -> rastertoricohddst)"
        echo "    • Ricoh SP 310/325/3710     (DDST Protocol  -> rastertoricohddst)"
        echo "=================================================================="
    fi
fi
