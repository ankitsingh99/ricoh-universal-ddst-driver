#!/usr/bin/env bash
# ==============================================================================
# Ricoh Universal DDST Driver - macOS PKG Installer Generator
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$(git describe --tags --always 2>/dev/null | sed 's/^v//' || echo "0.1.0")}"
PKG_OUTPUT_DIR="${2:-${SCRIPT_DIR}/dist}"
mkdir -p "${PKG_OUTPUT_DIR}"
PKG_OUTPUT_DIR="$(cd "${PKG_OUTPUT_DIR}" && pwd)"

echo "========================================================"
echo " Building macOS PKG: Ricoh Universal DDST Driver v${VERSION}"
echo "========================================================"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "Warning: pkgbuild is a macOS native utility. If running outside macOS, this step requires macOS."
    if ! command -v pkgbuild >/dev/null 2>&1; then
        echo "Error: pkgbuild not found. Cannot build macOS .pkg on this host."
        exit 1
    fi
fi

BUILD_ROOT="$(mktemp -d -t ricoh_pkg_build_XXXXXX)"
SCRIPTS_DIR="$(mktemp -d -t ricoh_pkg_scripts_XXXXXX)"
trap 'rm -rf "${BUILD_ROOT}" "${SCRIPTS_DIR}"' EXIT

PAYLOAD_ROOT="${BUILD_ROOT}/payload"
mkdir -p "${PAYLOAD_ROOT}/Library/Printers/Ricoh/Filter"
mkdir -p "${PAYLOAD_ROOT}/Library/Printers/PPDs/Contents/Resources"
mkdir -p "${PKG_OUTPUT_DIR}"

# 1. Build binaries if needed
cd "${SCRIPT_DIR}"
make build

# 2. Copy binaries
install -m 755 "${SCRIPT_DIR}/rastertoricohddst" "${PAYLOAD_ROOT}/Library/Printers/Ricoh/Filter/rastertoricohddst"
install -m 755 "${SCRIPT_DIR}/rastertoricohjbig" "${PAYLOAD_ROOT}/Library/Printers/Ricoh/Filter/rastertoricohjbig"

# 3. Process and install PPDs with absolute macOS filter paths
for ppd in "${SCRIPT_DIR}"/ppd/*.ppd "${SCRIPT_DIR}"/ricoh-sp200.ppd; do
    if [ -f "${ppd}" ]; then
        filename="$(basename "${ppd}")"
        sed 's|application/vnd.cups-raster 0 rastertoricohddst|application/vnd.cups-raster 0 /Library/Printers/Ricoh/Filter/rastertoricohddst|g; s|application/vnd.cups-raster 0 rastertoricohjbig|application/vnd.cups-raster 0 /Library/Printers/Ricoh/Filter/rastertoricohjbig|g' "${ppd}" > "${PAYLOAD_ROOT}/Library/Printers/PPDs/Contents/Resources/${filename}"
        chmod 644 "${PAYLOAD_ROOT}/Library/Printers/PPDs/Contents/Resources/${filename}"
    fi
done

# 4. Create postinstall script
cat << 'EOF' > "${SCRIPTS_DIR}/postinstall"
#!/bin/bash
set -e

# Fix permissions
chown -R root:wheel /Library/Printers/Ricoh 2>/dev/null || true
chmod -R 755 /Library/Printers/Ricoh 2>/dev/null || true
chown root:wheel /Library/Printers/PPDs/Contents/Resources/ricoh-sp*.ppd 2>/dev/null || true
chmod 644 /Library/Printers/PPDs/Contents/Resources/ricoh-sp*.ppd 2>/dev/null || true

# Remove quarantine flags if any
xattr -d com.apple.quarantine /Library/Printers/Ricoh/Filter/rastertoricohddst 2>/dev/null || true
xattr -d com.apple.quarantine /Library/Printers/Ricoh/Filter/rastertoricohjbig 2>/dev/null || true

# Refresh CUPS
launchctl kickstart -k system/org.cups.cupsd 2>/dev/null || true

echo "Ricoh Universal DDST Driver installed successfully."
exit 0
EOF
chmod 755 "${SCRIPTS_DIR}/postinstall"

# 5. Build PKG using pkgbuild
PKG_FILE="${PKG_OUTPUT_DIR}/ricoh-universal-ddst-driver-${VERSION}-macOS.pkg"

export COPYFILE_DISABLE=1
dot_clean -m "${PAYLOAD_ROOT}" 2>/dev/null || true
find "${PAYLOAD_ROOT}" -name '._*' -delete 2>/dev/null || true
xattr -rc "${PAYLOAD_ROOT}" 2>/dev/null || true

pkgbuild \
    --root "${PAYLOAD_ROOT}" \
    --scripts "${SCRIPTS_DIR}" \
    --identifier "io.github.ankitsingh99.ricoh-universal-ddst-driver" \
    --version "${VERSION}" \
    --ownership "recommended" \
    --install-location "/" \
    "${PKG_FILE}"

echo ""
echo "[OK] Successfully built macOS package:"
echo "     ${PKG_FILE}"
ls -lh "${PKG_FILE}"
