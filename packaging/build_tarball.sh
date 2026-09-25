#!/usr/bin/env bash
# ==============================================================================
# Ricoh Universal DDST Driver - Release Archive (.tar.gz / .zip) Generator
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$(git describe --tags --always 2>/dev/null | sed 's/^v//' || echo "0.1.0")}"
OUTPUT_DIR="${2:-${SCRIPT_DIR}/dist}"
mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"

export COPYFILE_DISABLE=1
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

echo "========================================================"
echo " Building Release Archives: v${VERSION} (${OS}-${ARCH})"
echo "========================================================"

# 1. Build binaries
cd "${SCRIPT_DIR}"
make build

# 2. Package Binary Archive
BIN_ARCHIVE_NAME="ricoh-universal-ddst-driver-${VERSION}-${OS}-${ARCH}"
BIN_STAGE_DIR="$(mktemp -d -t ricoh_tar_bin_XXXXXX)/${BIN_ARCHIVE_NAME}"
mkdir -p "${BIN_STAGE_DIR}"

cp -r ppd "${BIN_STAGE_DIR}/"
cp ricoh-sp200.ppd "${BIN_STAGE_DIR}/"
cp rastertoricohddst "${BIN_STAGE_DIR}/"
cp rastertoricohjbig "${BIN_STAGE_DIR}/"
cp setup.sh test_print.sh uninstall.sh Makefile README.md LICENSE AUTHORS.md "${BIN_STAGE_DIR}/"
chmod 755 "${BIN_STAGE_DIR}"/*.sh "${BIN_STAGE_DIR}/rastertoricohddst" "${BIN_STAGE_DIR}/rastertoricohjbig"

(
    cd "$(dirname "${BIN_STAGE_DIR}")"
    tar -czf "${OUTPUT_DIR}/${BIN_ARCHIVE_NAME}.tar.gz" "${BIN_ARCHIVE_NAME}"
    if command -v zip >/dev/null 2>&1; then
        zip -rq "${OUTPUT_DIR}/${BIN_ARCHIVE_NAME}.zip" "${BIN_ARCHIVE_NAME}"
    fi
)
rm -rf "$(dirname "${BIN_STAGE_DIR}")"

# 3. Package Source Archive
SRC_ARCHIVE_NAME="ricoh-universal-ddst-driver-${VERSION}-source"
SRC_STAGE_DIR="$(mktemp -d -t ricoh_tar_src_XXXXXX)/${SRC_ARCHIVE_NAME}"
mkdir -p "${SRC_STAGE_DIR}"

cp -r ppd "${SRC_STAGE_DIR}/"
cp -r packaging "${SRC_STAGE_DIR}/"
cp ricoh-sp200.ppd rastertoricohddst.c rastertoricohjbig.c "${SRC_STAGE_DIR}/"
cp setup.sh test_print.sh uninstall.sh Makefile README.md LICENSE AUTHORS.md CONTRIBUTING.md CODE_OF_CONDUCT.md SECURITY.md "${SRC_STAGE_DIR}/"
chmod 755 "${SRC_STAGE_DIR}"/*.sh "${SRC_STAGE_DIR}/packaging"/*.sh

(
    cd "$(dirname "${SRC_STAGE_DIR}")"
    tar -czf "${OUTPUT_DIR}/${SRC_ARCHIVE_NAME}.tar.gz" "${SRC_ARCHIVE_NAME}"
)
rm -rf "$(dirname "${SRC_STAGE_DIR}")"

echo ""
echo "[OK] Generated Archives in ${OUTPUT_DIR}:"
ls -lh "${OUTPUT_DIR}"/*"${VERSION}"*
