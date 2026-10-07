#!/usr/bin/env bash
# ==============================================================================
# Ricoh Universal DDST Driver - Mobile & Network Printing Configuration
# Enables AirPrint (iOS) and IPP (Android / Windows / Linux) network printing
# with persistent mDNS advertisement and offline job spooling.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS="$(uname -s)"
LAUNCHAGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCHAGENT_PLIST="$LAUNCHAGENT_DIR/com.ricoh.airprint.plist"
AVAHI_SERVICE_FILE="/etc/avahi/services/ricoh-airprint.service"

show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --enable            Configure CUPS sharing and start AirPrint/IPP mDNS advertisement (default)
  --disable           Stop AirPrint/IPP advertisement and disable network sharing
  --status            Check current network sharing, queue, and mDNS broadcast status
  --printer <name>    Specify printer queue name (default: auto-detected Ricoh queue)
  --help, -h          Show this help message

Description:
  Enables any mobile phone (iPhone/iPad via AirPrint, Android via Default Print Service)
  or computer on the local Wi-Fi/LAN network to print to the Ricoh laser printer through
  this machine.

  Key Behaviors:
  1. The printer name remains discoverable on all mobile devices 24/7, even when
     the Ricoh printer is powered off or disconnected from USB.
  2. Print jobs sent from mobile devices are received and safely queued on this machine.
  3. When the Ricoh printer is turned on and connected via USB, all queued jobs
     print automatically without manual intervention.
EOF
}

detect_printer() {
    local target="${1:-}"
    if [ -n "$target" ]; then
        echo "$target"
        return
    fi

    local detected
    detected=$(lpstat -p 2>/dev/null | grep -i "Ricoh" | awk '{print $2}' | head -1 || true)
    if [ -n "$detected" ]; then
        echo "$detected"
        return
    fi

    # Fallback to default
    echo "Ricoh_SP_200_DDST"
}

get_friendly_name() {
    local q="$1"
    # Convert queue name like Ricoh_SP_200_DDST to friendly "Ricoh SP 200 (AirPrint)"
    echo "$q" | sed 's/_/ /g' | sed 's/ DDST//g'
}

get_local_ip() {
    if [ "$OS" = "Darwin" ]; then
        ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || ifconfig | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}' | head -1 || echo "unknown"
    else
        hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown"
    fi
}

get_local_hostname() {
    if [ "$OS" = "Darwin" ]; then
        local name
        name="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
        echo "${name}.local"
    else
        echo "$(hostname -s).local"
    fi
}

enable_sharing() {
    local q="$1"
    local friendly
    friendly="$(get_friendly_name "$q")"
    local hostname
    hostname="$(get_local_hostname)"
    local local_ip
    local_ip="$(get_local_ip)"

    echo "========================================================"
    echo " Enabling Mobile & Network Printing for Ricoh Driver"
    echo " Detected OS: $OS"
    echo " Printer Queue: $q"
    echo " Host: $hostname (IP: $local_ip)"
    echo "========================================================"
    echo ""

    # 1. Enable CUPS network sharing & remote access
    echo "[1/4] Configuring CUPS daemon for remote sharing..."
    if command -v cupsctl >/dev/null 2>&1; then
        cupsctl --share-printers --remote-any
        echo "  [OK] CUPS printer sharing and remote access enabled."
    else
        echo "  [WARN] cupsctl not found. Ensure cupsd is configured to listen on port 631."
    fi

    # 2. Configure printer queue options
    echo "[2/4] Setting queue policies (offline spooling + shared)..."
    lpadmin -p "$q" -o printer-is-shared=true -o printer-error-policy=retry-current-job
    cupsenable "$q" 2>/dev/null || true
    cupsaccept "$q" 2>/dev/null || true
    echo "  [OK] Queue '$q' configured:"
    echo "       - printer-is-shared: true"
    echo "       - error-policy: retry-current-job (offline holding without pausing queue)"

    # 3. Setup persistent AirPrint / IPP mDNS broadcast
    echo "[3/4] Setting up persistent mDNS AirPrint / IPP advertisement..."
    if [ "$OS" = "Darwin" ]; then
        mkdir -p "$LAUNCHAGENT_DIR"
        cat << EOF > "$LAUNCHAGENT_PLIST"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ricoh.airprint</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/dns-sd</string>
        <string>-R</string>
        <string>${friendly} (AirPrint)</string>
        <string>_ipp._tcp,_universal</string>
        <string>local.</string>
        <string>631</string>
        <string>txtvers=1</string>
        <string>qtotal=1</string>
        <string>rp=printers/${q}</string>
        <string>ty=${friendly}</string>
        <string>adminurl=http://${hostname}:631/printers/${q}</string>
        <string>pdl=application/pdf,image/jpeg</string>
        <string>URF=none</string>
        <string>air=none</string>
    </array>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/ricoh_airprint.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/ricoh_airprint.err</string>
</dict>
</plist>
EOF
        # Load the LaunchAgent
        launchctl unload "$LAUNCHAGENT_PLIST" 2>/dev/null || true
        launchctl load "$LAUNCHAGENT_PLIST"
        sleep 1
        echo "  [OK] macOS LaunchAgent registered: $LAUNCHAGENT_PLIST"
        echo "  [OK] AirPrint mDNS service advertised as: '${friendly} (AirPrint)'"

    elif [ -d "/etc/avahi/services" ]; then
        if [ "$EUID" -ne 0 ]; then
            echo "  [*] Writing Avahi service requires sudo on Linux..."
            sudo bash -c "cat << 'EOF' > '$AVAHI_SERVICE_FILE'
<?xml version=\"1.0\" standalone='no'?>
<!DOCTYPE service-group SYSTEM \"avahi-service.dtd\">
<service-group>
  <name replace-wildcards=\"yes\">${friendly} (AirPrint)</name>
  <service>
    <type>_ipp._tcp</type>
    <subtype>_universal._sub._ipp._tcp</subtype>
    <port>631</port>
    <txt-record>txtvers=1</txt-record>
    <txt-record>qtotal=1</txt-record>
    <txt-record>rp=printers/${q}</txt-record>
    <txt-record>ty=${friendly}</txt-record>
    <txt-record>adminurl=http://${hostname}:631/printers/${q}</txt-record>
    <txt-record>pdl=application/pdf,image/jpeg</txt-record>
    <txt-record>URF=none</txt-record>
    <txt-record>air=none</txt-record>
  </service>
</service-group>
EOF"
            sudo systemctl reload avahi-daemon 2>/dev/null || sudo service avahi-daemon reload 2>/dev/null || true
            echo "  [OK] Linux Avahi service registered: $AVAHI_SERVICE_FILE"
        fi
    else
        echo "  [*] Note: Avahi directory not found. Standard CUPS mDNS broadcasting will be used."
    fi

    # 4. Final verification
    echo "[4/4] Verifying network listener..."
    if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:631/printers/${q}" | grep -q "200"; then
        echo "  [OK] CUPS IPP endpoint is responsive at http://127.0.0.1:631/printers/${q}"
    else
        echo "  [WARN] IPP endpoint returned non-200. Check CUPS status."
    fi

    echo ""
    echo "========================================================"
    echo "  NETWORK & MOBILE PRINTING IS NOW ACTIVE"
    echo "========================================================"
    echo "  1. On iPhone / iPad:"
    echo "     - Tap Share -> Print in any app (Photos, Safari, Mail, Files)."
    echo "     - '${friendly} (AirPrint)' will appear in the printer list."
    echo "  2. On Android:"
    echo "     - Open Document -> Print -> Select '${q}' or '${friendly}'"
    echo "       (via Android Default Print Service or Mopria)."
    echo "  3. On Other Computers (Mac/Windows/Linux):"
    echo "     - Connect to network printer URI: ipp://${local_ip}:631/printers/${q}"
    echo ""
    echo "  Behavior:"
    echo "  - The printer name is always visible even when the printer is off."
    echo "  - Jobs print immediately when the printer connects via USB."
    echo "  - If offline, jobs wait safely in the queue on this machine."
    echo "========================================================"
}

disable_sharing() {
    local q="$1"
    echo "Disabling network sharing for '$q'..."

    # Disable queue sharing
    lpadmin -p "$q" -o printer-is-shared=false 2>/dev/null || true

    # Remove LaunchAgent / Avahi service
    if [ "$OS" = "Darwin" ] && [ -f "$LAUNCHAGENT_PLIST" ]; then
        launchctl unload "$LAUNCHAGENT_PLIST" 2>/dev/null || true
        rm -f "$LAUNCHAGENT_PLIST"
        echo "  [OK] macOS AirPrint LaunchAgent removed."
    fi

    if [ -f "$AVAHI_SERVICE_FILE" ]; then
        sudo rm -f "$AVAHI_SERVICE_FILE" 2>/dev/null || rm -f "$AVAHI_SERVICE_FILE" 2>/dev/null || true
        echo "  [OK] Linux Avahi service removed."
    fi

    echo "Network sharing disabled for '$q'."
}

show_status() {
    local q="$1"
    local local_ip
    local_ip="$(get_local_ip)"
    local hostname
    hostname="$(get_local_hostname)"

    echo "========================================================"
    echo " Ricoh Network Printing Status"
    echo " Printer Queue: $q"
    echo " Host:          $hostname"
    echo " Local IP:      $local_ip"
    echo "========================================================"
    echo ""
    echo "--- CUPS Server Configuration ---"
    cupsctl 2>/dev/null || echo "cupsctl unavailable"
    echo ""
    echo "--- Queue Status ($q) ---"
    lpstat -p "$q" -l 2>/dev/null || echo "Queue '$q' not registered"
    echo ""
    echo "--- Queued Jobs ($q) ---"
    lpstat -o "$q" 2>/dev/null || echo "No active jobs in queue."
    echo ""
    echo "--- mDNS / AirPrint Service ---"
    if [ "$OS" = "Darwin" ]; then
        if [ -f "$LAUNCHAGENT_PLIST" ]; then
            echo "LaunchAgent file: Present ($LAUNCHAGENT_PLIST)"
            if launchctl list | grep -q "com.ricoh.airprint"; then
                echo "LaunchAgent state: RUNNING (active background mDNS broadcast)"
            else
                echo "LaunchAgent state: NOT LOADED"
            fi
        else
            echo "LaunchAgent file: Not installed"
        fi
    elif [ -f "$AVAHI_SERVICE_FILE" ]; then
        echo "Avahi service file: Present ($AVAHI_SERVICE_FILE)"
    else
        echo "No custom mDNS service file found."
    fi
    echo "========================================================"
}

# --- Main Entry Point ---
PRINTER_ARG=""
ACTION="enable"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --enable)
            ACTION="enable"
            shift
            ;;
        --disable)
            ACTION="disable"
            shift
            ;;
        --status)
            ACTION="status"
            shift
            ;;
        --printer)
            PRINTER_ARG="$2"
            shift 2
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

TARGET_PRINTER=$(detect_printer "$PRINTER_ARG")

case "$ACTION" in
    enable)
        enable_sharing "$TARGET_PRINTER"
        ;;
    disable)
        disable_sharing "$TARGET_PRINTER"
        ;;
    status)
        show_status "$TARGET_PRINTER"
        ;;
esac
