#!/usr/bin/env bash
# ==============================================================================
# Ricoh Universal DDST Driver - Debian/Ubuntu (.deb) Package Generator
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$(git describe --tags --always 2>/dev/null | sed 's/^v//' || echo "0.1.0")}"
DEB_OUTPUT_DIR="${2:-${SCRIPT_DIR}/dist}"
mkdir -p "${DEB_OUTPUT_DIR}"
DEB_OUTPUT_DIR="$(cd "${DEB_OUTPUT_DIR}" && pwd)"
export COPYFILE_DISABLE=1

# Determine architecture
if command -v dpkg >/dev/null 2>&1; then
    ARCH="$(dpkg --print-architecture)"
else
    UNAME_M="$(uname -m)"
    case "${UNAME_M}" in
        x86_64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l)  ARCH="armhf" ;;
        i386|i686) ARCH="i386" ;;
        *)       ARCH="${UNAME_M}" ;;
    esac
fi

PACKAGE_NAME="ricoh-universal-ddst-driver"
DEB_FILE="${DEB_OUTPUT_DIR}/${PACKAGE_NAME}_${VERSION}_${ARCH}.deb"

echo "========================================================"
echo " Building Debian Package: ${PACKAGE_NAME} v${VERSION} (${ARCH})"
echo "========================================================"

BUILD_ROOT="$(mktemp -d -t ricoh_deb_build_XXXXXX)"
trap 'rm -rf "${BUILD_ROOT}"' EXIT

mkdir -p "${BUILD_ROOT}/DEBIAN"
mkdir -p "${BUILD_ROOT}/usr/lib/cups/filter"
mkdir -p "${BUILD_ROOT}/usr/share/ppd/cupsfilters"
mkdir -p "${BUILD_ROOT}/usr/share/doc/${PACKAGE_NAME}"
mkdir -p "${DEB_OUTPUT_DIR}"

# 1. Build binaries if needed
cd "${SCRIPT_DIR}"
if [ ! -f "rastertoricohddst" ] || [ ! -f "rastertoricohjbig" ]; then
    make build
fi

# 2. Copy binaries
install -m 755 "${SCRIPT_DIR}/rastertoricohddst" "${BUILD_ROOT}/usr/lib/cups/filter/rastertoricohddst"
install -m 755 "${SCRIPT_DIR}/rastertoricohjbig" "${BUILD_ROOT}/usr/lib/cups/filter/rastertoricohjbig"

# 3. Copy PPD files
install -m 644 "${SCRIPT_DIR}"/ppd/*.ppd "${BUILD_ROOT}/usr/share/ppd/cupsfilters/"
install -m 644 "${SCRIPT_DIR}/ricoh-sp200.ppd" "${BUILD_ROOT}/usr/share/ppd/cupsfilters/"

# 4. Copy docs and license
install -m 644 "${SCRIPT_DIR}/README.md" "${BUILD_ROOT}/usr/share/doc/${PACKAGE_NAME}/"
install -m 644 "${SCRIPT_DIR}/LICENSE" "${BUILD_ROOT}/usr/share/doc/${PACKAGE_NAME}/copyright"

# 5. Create control file
cat << EOF > "${BUILD_ROOT}/DEBIAN/control"
Package: ${PACKAGE_NAME}
Version: ${VERSION}
Section: text
Priority: optional
Architecture: ${ARCH}
Maintainer: Ankit Singh <ankitsingh99@users.noreply.github.com>
Depends: libc6 (>= 2.14), libjbig0 (>= 2.0) | libjbig-dev, cups (>= 1.5.0) | cups-client, ghostscript
Recommends: cups-filters | libcupsfilters1 | cups-daemon
Suggests: system-config-printer
Homepage: https://github.com/ankitsingh99/ricoh-universal-ddst-driver
Description: Universal CUPS DDST/GDI printer driver for Ricoh Aficio SP Series
 High-performance CUPS raster filter and PPD driver suite supporting Ricoh
 SP 100, SP 110, SP 150, SP 200, SP 210, SP 230, and SP 310 series laser printers.
 Provides native raster conversion and JBIG stream compression.
EOF

# 6. Create postinst script
cat << 'EOF' > "${BUILD_ROOT}/DEBIAN/postinst"
#!/bin/sh
set -e

if [ "$1" = "configure" ]; then
    # Fix permissions
    chmod 755 /usr/lib/cups/filter/rastertoricohddst 2>/dev/null || true
    chmod 755 /usr/lib/cups/filter/rastertoricohjbig 2>/dev/null || true
    chmod 644 /usr/share/ppd/cupsfilters/ricoh-sp*.ppd 2>/dev/null || true

    # Restart or reload CUPS daemon if running
    if command -v systemctl >/dev/null 2>&1; then
        systemctl try-restart cups.service 2>/dev/null || systemctl try-reload-or-restart cups.service 2>/dev/null || true
    elif command -v service >/dev/null 2>&1; then
        service cups restart 2>/dev/null || true
    fi
    echo "Ricoh Universal DDST CUPS driver installed successfully."
fi

exit 0
EOF
chmod 755 "${BUILD_ROOT}/DEBIAN/postinst"

# 7. Create postrm script
cat << 'EOF' > "${BUILD_ROOT}/DEBIAN/postrm"
#!/bin/sh
set -e

if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    if command -v systemctl >/dev/null 2>&1; then
        systemctl try-restart cups.service 2>/dev/null || true
    elif command -v service >/dev/null 2>&1; then
        service cups restart 2>/dev/null || true
    fi
fi

exit 0
EOF
chmod 755 "${BUILD_ROOT}/DEBIAN/postrm"

# 8. Build .deb
if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb --build --root-owner-group "${BUILD_ROOT}" "${DEB_FILE}"
else
    # Fallback to creating a standard Debian archive using Python/tar if dpkg-deb is missing
    echo "Note: dpkg-deb not found. Creating Debian archive using Python ar packager..."
    (
        cd "${BUILD_ROOT}"
        echo "2.0" > debian-binary
        tar -czf control.tar.gz -C DEBIAN .
        tar -czf data.tar.gz usr
        python3 -c "
import sys

def write_ar_member(out, filename, data):
    name = (filename.ljust(16))[:16]
    mtime = '0'.ljust(12)
    uid = '0'.ljust(6)
    gid = '0'.ljust(6)
    mode = '100644'.ljust(8)
    size = str(len(data)).ljust(10)
    magic = b'\x60\x0a'
    hdr = (name + mtime + uid + gid + mode + size).encode('ascii') + magic
    out.write(hdr)
    out.write(data)
    if len(data) % 2 != 0:
        out.write(b'\x0a')

deb_file = sys.argv[1]
with open(deb_file, 'wb') as f:
    f.write(b'!<arch>\n')
    for m in ['debian-binary', 'control.tar.gz', 'data.tar.gz']:
        with open(m, 'rb') as mf:
            write_ar_member(f, m, mf.read())
" "${DEB_FILE}"
    )
fi

echo ""
echo "[OK] Successfully built Debian package:"
echo "     ${DEB_FILE}"
ls -lh "${DEB_FILE}"
