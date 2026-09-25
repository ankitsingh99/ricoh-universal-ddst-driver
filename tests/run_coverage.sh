#!/usr/bin/env bash
# ==============================================================================
# Ricoh DDST Driver - Comprehensive Coverage & Unit Test Suite (>= 95% Target)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="${SCRIPT_DIR}/tests"
TMP_DIR="$(mktemp -d -t ricoh_coverage_XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

cd "${SCRIPT_DIR}"

UNAME="$(uname -s)"
if [ "$UNAME" = "Darwin" ]; then
    BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
    CPPFLAGS="-I${BREW_PREFIX}/include"
    LDFLAGS="-L${BREW_PREFIX}/lib"
    LIBS="-lcups -lcupsimage -ljbig"
else
    CPPFLAGS="$(cups-config --cflags 2>/dev/null || true)"
    LIBS="$(cups-config --libs 2>/dev/null || echo -lcups) -lcupsimage -ljbig"
    LDFLAGS=""
fi

echo "========================================================"
echo " Running Ricoh DDST Driver Test & Coverage Suite"
echo " Target Code Coverage: >= 95%"
echo " Detected OS: ${UNAME}"
echo "========================================================"

# 1. Clean previous coverage files
rm -f *.gcda *.gcno *.gcov *.o

# 2. Build test raster generator
echo "[1/5] Building test raster generator..."
gcc -O2 ${CPPFLAGS} ${LDFLAGS} -o "${TMP_DIR}/generate_test_raster" "${TEST_DIR}/generate_test_raster.c" ${LIBS}

# 3. Generate test streams
echo "[2/5] Generating test raster streams..."
"${TMP_DIR}/generate_test_raster" "${TMP_DIR}/mono.ras" mono
"${TMP_DIR}/generate_test_raster" "${TMP_DIR}/large.ras" large
"${TMP_DIR}/generate_test_raster" "${TMP_DIR}/multipage.ras" multipage
"${TMP_DIR}/generate_test_raster" "${TMP_DIR}/legal.ras" legal
"${TMP_DIR}/generate_test_raster" "${TMP_DIR}/duplex.ras" duplex
"${TMP_DIR}/generate_test_raster" "${TMP_DIR}/gray.ras" gray
"${TMP_DIR}/generate_test_raster" "${TMP_DIR}/gray3.ras" gray_cspace3
"${TMP_DIR}/generate_test_raster" "${TMP_DIR}/rgb.ras" rgb
"${TMP_DIR}/generate_test_raster" "${TMP_DIR}/empty.ras" empty
echo "Corrupt raster data" > "${TMP_DIR}/corrupt.ras"

# 4. Build filters with coverage instrumentation
echo "[3/5] Compiling filter binaries with coverage instrumentation..."
gcc -O0 -g ${CPPFLAGS} -c "${TEST_DIR}/test_mocks.c" -o "${TMP_DIR}/test_mocks.o"

gcc -O0 -g --coverage -DSTATIC="" -DTESTING -Dmain=driver_main_ddst ${CPPFLAGS} -c rastertoricohddst.c -o rastertoricohddst.o
gcc --coverage rastertoricohddst.o "${TMP_DIR}/test_mocks.o" -Ddriver_main=driver_main_ddst "${TEST_DIR}/main_driver.c" ${LDFLAGS} -o "${TMP_DIR}/rastertoricohddst" ${LIBS}

gcc -O0 -g --coverage -DSTATIC="" -DTESTING -Dmain=driver_main_jbig ${CPPFLAGS} -c rastertoricohjbig.c -o rastertoricohjbig.o
gcc --coverage rastertoricohjbig.o "${TMP_DIR}/test_mocks.o" -Ddriver_main=driver_main_jbig "${TEST_DIR}/main_driver.c" ${LDFLAGS} -o "${TMP_DIR}/rastertoricohjbig" ${LIBS}

# Build unit test runners linking against the instrumented object files
gcc ${CPPFLAGS} -c "${TEST_DIR}/test_unit_ddst.c" -o "${TMP_DIR}/test_unit_ddst.o"
gcc --coverage "${TMP_DIR}/test_unit_ddst.o" rastertoricohddst.o "${TMP_DIR}/test_mocks.o" ${LDFLAGS} -o "${TMP_DIR}/test_unit_ddst" ${LIBS}

gcc ${CPPFLAGS} -c "${TEST_DIR}/test_unit_jbig.c" -o "${TMP_DIR}/test_unit_jbig.o"
gcc --coverage "${TMP_DIR}/test_unit_jbig.o" rastertoricohjbig.o "${TMP_DIR}/test_mocks.o" ${LDFLAGS} -o "${TMP_DIR}/test_unit_jbig" ${LIBS}

# 5. Execute integration & unit test cases
echo "[4/5] Executing test suite against rastertoricohddst..."

"${TMP_DIR}/rastertoricohddst" < "${TMP_DIR}/mono.ras" > /dev/null
"${TMP_DIR}/rastertoricohddst" 100 user "Large Test" 1 "" "${TMP_DIR}/large.ras" > /dev/null
"${TMP_DIR}/rastertoricohddst" 101 user "Multi-page Test" 2 "" "${TMP_DIR}/multipage.ras" > /dev/null
"${TMP_DIR}/rastertoricohddst" 102 user "Legal Duplex" 1 "Duplex=DuplexNoTumble" "${TMP_DIR}/legal.ras" > /dev/null
"${TMP_DIR}/rastertoricohddst" 103 user "Letter Duplex" 3 "" "${TMP_DIR}/duplex.ras" > /dev/null
"${TMP_DIR}/rastertoricohddst" 104 user "Gray Test" -1 "" "${TMP_DIR}/gray.ras" > /dev/null
"${TMP_DIR}/rastertoricohddst" 105 user "Gray Black" 0 "" "${TMP_DIR}/gray3.ras" > /dev/null
"${TMP_DIR}/rastertoricohddst" 106 user "RGB Test" 1 "" "${TMP_DIR}/rgb.ras" > /dev/null
"${TMP_DIR}/rastertoricohddst" 107 user "Empty Job" 1 "" "${TMP_DIR}/empty.ras" > /dev/null

set +e
"${TMP_DIR}/rastertoricohddst" 108 user "Missing" 1 "" "${TMP_DIR}/nonexistent.ras" > /dev/null 2>&1
"${TMP_DIR}/rastertoricohddst" 109 user "Corrupt" 1 "" "${TMP_DIR}/corrupt.ras" > /dev/null 2>&1
set -e

# Run unit tests and error injection tests
"${TMP_DIR}/test_unit_ddst" "${TMP_DIR}/mono.ras" "${TMP_DIR}/gray.ras"

echo "Executing test suite against rastertoricohjbig..."
"${TMP_DIR}/rastertoricohjbig" < "${TMP_DIR}/mono.ras" > /dev/null
"${TMP_DIR}/rastertoricohjbig" 200 user "Large Test" 1 "" "${TMP_DIR}/large.ras" > /dev/null
"${TMP_DIR}/rastertoricohjbig" 201 user "Multi-page Test" 2 "" "${TMP_DIR}/multipage.ras" > /dev/null
"${TMP_DIR}/rastertoricohjbig" 202 user "Legal Test" 1 "" "${TMP_DIR}/legal.ras" > /dev/null
"${TMP_DIR}/rastertoricohjbig" 203 user "Letter Test" 3 "" "${TMP_DIR}/duplex.ras" > /dev/null
"${TMP_DIR}/rastertoricohjbig" 204 user "Gray Test" 1 "" "${TMP_DIR}/gray.ras" > /dev/null
"${TMP_DIR}/rastertoricohjbig" 205 user "Gray3 Test" 1 "" "${TMP_DIR}/gray3.ras" > /dev/null
"${TMP_DIR}/rastertoricohjbig" 206 user "RGB Test" 1 "" "${TMP_DIR}/rgb.ras" > /dev/null
"${TMP_DIR}/rastertoricohjbig" 207 user "Empty Test" 1 "" "${TMP_DIR}/empty.ras" > /dev/null

set +e
"${TMP_DIR}/rastertoricohjbig" 208 user "Missing" 1 "" "${TMP_DIR}/nonexistent.ras" > /dev/null 2>&1
"${TMP_DIR}/rastertoricohjbig" 209 user "Corrupt" 1 "" "${TMP_DIR}/corrupt.ras" > /dev/null 2>&1
set -e

"${TMP_DIR}/test_unit_jbig" "${TMP_DIR}/mono.ras" "${TMP_DIR}/gray.ras"

# 6. Generate gcov report
echo ""
echo "========================================================"
echo " [5/5] Generating Code Coverage Report (gcov)"
echo "========================================================"

gcov rastertoricohddst.gcno rastertoricohjbig.gcno > "${TMP_DIR}/gcov.log"
cat "${TMP_DIR}/gcov.log"

# Parse coverage percentages
DDST_COV=$(grep -A 1 "File 'rastertoricohddst.c'" "${TMP_DIR}/gcov.log" | grep "Lines executed:" | sed -E 's/.*Lines executed:([0-9.]+)%.*/\1/')
JBIG_COV=$(grep -A 1 "File 'rastertoricohjbig.c'" "${TMP_DIR}/gcov.log" | grep "Lines executed:" | sed -E 's/.*Lines executed:([0-9.]+)%.*/\1/')

echo ""
echo "--------------------------------------------------------"
echo " Coverage Summary:"
echo "   rastertoricohddst.c Line Coverage: ${DDST_COV}%"
echo "   rastertoricohjbig.c Line Coverage: ${JBIG_COV}%"
echo "--------------------------------------------------------"

# 7. Assert coverage >= 95%
python3 -c "
ddst = float('${DDST_COV}')
jbig = float('${JBIG_COV}')
avg = (ddst + jbig) / 2.0
print(f'Overall average coverage: {avg:.2f}%')
assert ddst >= 95.0, f'rastertoricohddst coverage {ddst}% is below 95%'
assert jbig >= 95.0, f'rastertoricohjbig coverage {jbig}% is below 95%'
print('\n*** SUCCESS: 95%+ Code Coverage Achieved! ***\n')
"

# Clean coverage artifacts
rm -f *.gcda *.gcno *.gcov *.o
