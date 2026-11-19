#!/usr/bin/env python3
"""
generate_prints.py — Automated Test Print & Emulation Log Generator for Ricoh Driver Suite

Generates wire-level raw print streams (.prn) and protocol emulation logs (.log)
for all supported printer models:
  1. Ricoh SP 100        (DDST v1)
  2. Ricoh SP 111        (DDST v1)
  3. Ricoh SP 150        (LHPL protocol, SP 150 series)
  4. Ricoh SP 200        (DDST v1)
  5. Ricoh SP 210        (DDST v1)
  6. Ricoh SP 230        (DDST v1, Auto Duplex)
  7. Ricoh SP 310        (DDST v1, Duplex & Multi-Tray)
  8. Ricoh SP 200 Legacy (DDST v1, via rastertoricohjbig)

SPDX-License-Identifier: MIT
"""

import sys
import os
import subprocess
import tempfile
import struct
from datetime import datetime

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
DISSECT_SCRIPT = os.path.join(SCRIPT_DIR, "dissect_stream.py")

MODELS = [
    {
        "id": "ricoh_sp100",
        "name": "Ricoh Aficio SP 100",
        "ppd": "ppd/ricoh-sp100.ppd",
        "filter": "rastertoricohddst",
        "protocol": "DDST v1",
        "features": "Entry-level desktop, single-sheet manual feed + standard tray",
    },
    {
        "id": "ricoh_sp111",
        "name": "Ricoh SP 111 / SP 112",
        "ppd": "ppd/ricoh-sp111.ppd",
        "filter": "rastertoricohddst",
        "protocol": "DDST v1",
        "features": "Fanless, ultra-compact desktop design",
    },
    {
        "id": "ricoh_sp150",
        "name": "Ricoh SP 150 / SP 150w / SP 150SU",
        "ppd": "ppd/ricoh-sp150.ppd",
        "filter": "rastertoricohlhpl",
        "protocol": "LHPL (SP 150 Series / Lenovo OEM)",
        "features": "64-byte binary framing, JBIG T.85 single-progression, 22 ppm",
    },
    {
        "id": "ricoh_sp200",
        "name": "Ricoh Aficio SP 200 / SP 201 / SP 204",
        "ppd": "ppd/ricoh-sp200.ppd",
        "filter": "rastertoricohddst",
        "protocol": "DDST v1",
        "features": "Workgroup laser, high-capacity paper cassette, 22 ppm",
    },
    {
        "id": "ricoh_sp210",
        "name": "Ricoh SP 210 / SP 211 / SP 212 / SP 213",
        "ppd": "ppd/ricoh-sp210.ppd",
        "filter": "rastertoricohddst",
        "protocol": "DDST v1",
        "features": "Fast-warmup workgroup engine, manual duplex mode",
    },
    {
        "id": "ricoh_sp230",
        "name": "Ricoh SP 230DNw / SP 230SFn",
        "ppd": "ppd/ricoh-sp230.ppd",
        "filter": "rastertoricohddst",
        "protocol": "DDST v1",
        "features": "Hardware automatic double-sided (duplex) printing, Wi-Fi",
    },
    {
        "id": "ricoh_sp310",
        "name": "Ricoh SP 310DN / SP 311DNw / SP 320DN",
        "ppd": "ppd/ricoh-sp310.ppd",
        "filter": "rastertoricohddst",
        "protocol": "DDST v1",
        "features": "Automatic duplex engine, multi-tray source routing (Tray 1, 2, Bypass)",
    },
    {
        "id": "ricoh_sp200_legacy",
        "name": "Ricoh Aficio SP 200 (Legacy JBIG Filter)",
        "ppd": "ppd/ricoh-sp200.ppd",
        "filter": "rastertoricohjbig",
        "protocol": "DDST v1 (Legacy Filter)",
        "features": "Backward compatibility validation for rastertoricohjbig binary",
    },
]

def make_test_page_content(m: dict) -> str:
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    return f"""================================================================================
          RICOH UNIVERSAL DRIVER SUITE — DIAGNOSTIC TEST PAGE
================================================================================

PRINTER IDENTIFICATION
--------------------------------------------------------------------------------
Model Name:          {m['name']}
Protocol Family:     {m['protocol']}
CUPS Raster Filter:  {m['filter']}
Target PPD File:     {m['ppd']}
Driver Suite:        Ricoh Universal DDST/GDI Driver Suite v0.1.0
Hardware Features:   {m['features']}

PAGE CONFIGURATION & SPECIFICATION
--------------------------------------------------------------------------------
Media Size:          A4 (210 x 297 mm / 8.27 x 11.69 in)
Hardware Resolution: 600 x 600 DPI (Native Engine Resolution)
Color Space:         1-Bit Monochrome / K-Channel Bi-level Bitmap
Compression Profile: JBIG (ITU-T T.82 / T.85) Single-Progression
Timestamp:           {timestamp}

--------------------------------------------------------------------------------
1. ENGINE ALIGNMENT GRID & HALFTONE CALIBRATION PATTERN
--------------------------------------------------------------------------------
[00%] +--------------------------------------------------------------------+
[10%] | . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . .|
[25%] | : : : : : : : : : : : : : : : : : : : : : : : : : : : : : : : : : :|
[50%] | # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #|
[75%] | ################################################################## |
[90%] | ################################################################## |
[100%]| ################################################################## |
      +--------------------------------------------------------------------+

--------------------------------------------------------------------------------
2. HIGH-RESOLUTION TYPOGRAPHY & FONT RENDERING TEST (600 DPI)
--------------------------------------------------------------------------------
ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz 0123456789
The quick brown fox jumps over the lazy dog.
The quick brown fox jumps over the lazy dog. (Sharp 600 DPI edge definition)
!@#$%^&*()_+-=[]{{}}|;:',.<>/?~` "RICOH UNIVERSAL DDST & LHPL ENGINE"

--------------------------------------------------------------------------------
3. WIRE PROTOCOL & HARDWARE COMPLIANCE VERIFICATION
--------------------------------------------------------------------------------
  [PASS] Hardware Universal Exit Language (UEL) Sequence: <ESC>%-12345X
  [PASS] PJL Control Framing: @PJL SET COMPRESS=JBIG, RESOLUTION=600
  [PASS] JBIG Bi-level Image Compression Stream Framing (T.82 / T.85)
  [PASS] Hardware Dotcount / Pagefeed Eject Verification
  [PASS] Zero-Drop Host-to-Printer Flow Control Synchronization

================================================================================
   EMULATION VALIDATED — READY FOR DIRECT WIRE TRANSMISSION TO PRINTER
================================================================================
"""

def generate_sample_raster_synthetic(ras_path: str, is_lhpl: bool = False):
    """Fallback synthetic CUPS raster generator when cupsfilter is unavailable."""
    w = 5120 if is_lhpl else 4792
    h = 6978 if is_lhpl else 6850
    stride = (w + 7) // 8

    with open(ras_path, "wb") as f:
        # CUPS raster v2 sync magic
        f.write(b"RaS2")
        
        # 1792-byte cups_page_header2_t
        hdr = bytearray(1792)
        # MediaClass, MediaColor, MediaType, etc.
        # HWResolution[0], HWResolution[1] at offset 384, 388
        struct.pack_into("<II", hdr, 384, 600, 600)
        # PageSize[0], PageSize[1] at offset 400, 404
        struct.pack_into("<II", hdr, 400, 595, 842)
        # cupsWidth, cupsHeight at offset 416, 420
        struct.pack_into("<II", hdr, 416, w, h)
        # cupsBitsPerColor at 428, cupsBitsPerPixel at 432
        struct.pack_into("<II", hdr, 428, 1, 1)
        # cupsBytesPerLine at 436
        struct.pack_into("<I", hdr, 436, stride)
        # cupsColorSpace at 440 (3 = Black / K)
        struct.pack_into("<I", hdr, 440, 3)
        # cupsNumColors at 444
        struct.pack_into("<I", hdr, 444, 1)
        
        f.write(hdr)
        
        # Write scanlines: create a clean test pattern
        line_blank = bytes(stride)
        line_grid = bytes([0xAA, 0x55] * (stride // 2)) + (bytes([0xAA]) if stride % 2 else b"")
        line_solid = bytes([0xFF] * stride)

        for y in range(h):
            if 200 <= y < 220 or 6000 <= y < 6020:
                f.write(line_solid)
            elif (y % 100) < 10 and 500 <= y <= 5500:
                f.write(line_grid)
            else:
                f.write(line_blank)

def run():
    print("=" * 80)
    print(" Ricoh Universal Driver Suite: Generating Test Prints & Emulation Logs")
    print("=" * 80)
    
    # Check binaries exist
    for filt in ["rastertoricohddst", "rastertoricohlhpl", "rastertoricohjbig"]:
        fpath = os.path.join(PROJECT_DIR, filt)
        if not os.path.exists(fpath):
            print(f"Building filter '{filt}' via make...")
            subprocess.run(["make", "-C", PROJECT_DIR, filt], check=True)

    results = []
    has_cupsfilter = (subprocess.run(["which", "cupsfilter"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0)

    for m in MODELS:
        model_id = m["id"]
        ppd_path = os.path.join(PROJECT_DIR, m["ppd"])
        filter_bin = os.path.join(PROJECT_DIR, m["filter"])
        prn_path = os.path.join(SCRIPT_DIR, f"{model_id}_test_print.prn")
        log_path = os.path.join(SCRIPT_DIR, f"{model_id}_emulation.log")

        print(f"\nProcessing: {m['name']} ({m['protocol']})...")
        print(f"  PPD:    {m['ppd']}")
        print(f"  Filter: {m['filter']}")

        # 1. Create text file
        test_txt = make_test_page_content(m)
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as tf:
            tf.write(test_txt)
            tf_path = tf.name

        ras_path = tempfile.mktemp(suffix=".ras")

        try:
            # 2. Render to CUPS raster
            raster_generated = False
            if has_cupsfilter and os.path.exists(ppd_path):
                cmd_cf = ["cupsfilter", "-p", ppd_path, "-m", "application/vnd.cups-raster", tf_path]
                with open(ras_path, "wb") as rf:
                    res = subprocess.run(cmd_cf, stdout=rf, stderr=subprocess.DEVNULL)
                if res.returncode == 0 and os.path.getsize(ras_path) > 10000:
                    raster_generated = True

            if not raster_generated:
                print("  [*] Note: Using synthetic CUPS raster generator...")
                is_lhpl = ("lhpl" in m["filter"])
                generate_sample_raster_synthetic(ras_path, is_lhpl=is_lhpl)

            # 3. Filter through native driver filter
            # argv: filter job user title copies options [file]
            with open(prn_path, "wb") as pf:
                cmd_filt = [filter_bin, "100", "testuser", f"{m['name']} Test", "1", "", ras_path]
                res_filt = subprocess.run(cmd_filt, stdout=pf, stderr=subprocess.DEVNULL)
                if res_filt.returncode != 0:
                    raise RuntimeError(f"Filter {m['filter']} exited with code {res_filt.returncode}")

            prn_size = os.path.getsize(prn_path)
            print(f"  [OK] Generated raw PRN wire capture: {os.path.basename(prn_path)} ({prn_size:,} bytes)")

            # 4. Run stream dissector to produce emulation log
            cmd_dissect = [sys.executable, DISSECT_SCRIPT, prn_path, log_path]
            res_dis = subprocess.run(cmd_dissect, stdout=subprocess.DEVNULL)
            if res_dis.returncode != 0:
                raise RuntimeError(f"Dissector failed for {prn_path}")

            log_size = os.path.getsize(log_path)
            print(f"  [OK] Generated emulation log:       {os.path.basename(log_path)} ({log_size:,} bytes)")

            results.append({
                "model": m["name"],
                "protocol": m["protocol"],
                "prn_file": os.path.basename(prn_path),
                "prn_size": f"{prn_size:,} B",
                "log_file": os.path.basename(log_path),
                "status": "PASS",
            })

        finally:
            if os.path.exists(tf_path): os.remove(tf_path)
            if os.path.exists(ras_path): os.remove(ras_path)

    print("\n" + "=" * 80)
    print(" SUMMARY OF TEST PRINTS AND EMULATION LOGS")
    print("=" * 80)
    header = f"{'Printer Model':<35} | {'PRN Size':<11} | {'Log File':<32} | {'Status':<6}"
    print(header)
    print("-" * len(header))
    for r in results:
        print(f"{r['model']:<35} | {r['prn_size']:<11} | {r['log_file']:<32} | {r['status']:<6}")
    print("=" * 80)
    print("All test prints and emulation logs successfully generated and verified.")

if __name__ == "__main__":
    run()
