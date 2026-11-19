#!/usr/bin/env bash
# ==============================================================================
# generate_all.sh — Build filters and generate all test prints & emulation logs
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${ROOT_DIR}"

echo "Building driver filters..."
make -s build

echo "Executing Python test print generator..."
python3 "${SCRIPT_DIR}/generate_prints.py"

echo ""
echo "All test prints and emulation logs are up-to-date in ${SCRIPT_DIR}."
