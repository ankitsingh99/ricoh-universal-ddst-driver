# Ricoh Driver Suite — Test Prints & Protocol Emulation Logs

This directory contains pre-generated wire-level raw print captures (`.prn`) and hardware ASIC protocol emulation logs (`.log`) for every supported Ricoh laser printer model.

---

## 1. Supported Printer Models & Test Prints

| Printer Model | Protocol Family | Filter Binary | PPD File | Raw Wire Capture (.prn) | Emulation Log (.log) | Conformance |
| :--- | :--- | :--- | :--- | :--- | :--- | :---: |
| **Ricoh Aficio SP 100** | DDST v1 | `rastertoricohddst` | `ppd/ricoh-sp100.ppd` | [`ricoh_sp100_test_print.prn`](ricoh_sp100_test_print.prn) | [`ricoh_sp100_emulation.log`](ricoh_sp100_emulation.log) | **PASS** |
| **Ricoh SP 111 / SP 112** | DDST v1 | `rastertoricohddst` | `ppd/ricoh-sp111.ppd` | [`ricoh_sp111_test_print.prn`](ricoh_sp111_test_print.prn) | [`ricoh_sp111_emulation.log`](ricoh_sp111_emulation.log) | **PASS** |
| **Ricoh SP 150 / SP 150w** | LHPL | `rastertoricohlhpl` | `ppd/ricoh-sp150.ppd` | [`ricoh_sp150_test_print.prn`](ricoh_sp150_test_print.prn) | [`ricoh_sp150_emulation.log`](ricoh_sp150_emulation.log) | **PASS** |
| **Ricoh Aficio SP 200 / SP 201** | DDST v1 | `rastertoricohddst` | `ppd/ricoh-sp200.ppd` | [`ricoh_sp200_test_print.prn`](ricoh_sp200_test_print.prn) | [`ricoh_sp200_emulation.log`](ricoh_sp200_emulation.log) | **PASS** |
| **Ricoh SP 210 / SP 211** | DDST v1 | `rastertoricohddst` | `ppd/ricoh-sp210.ppd` | [`ricoh_sp210_test_print.prn`](ricoh_sp210_test_print.prn) | [`ricoh_sp210_emulation.log`](ricoh_sp210_emulation.log) | **PASS** |
| **Ricoh SP 230DNw / SFn** | DDST v1 (Duplex) | `rastertoricohddst` | `ppd/ricoh-sp230.ppd` | [`ricoh_sp230_test_print.prn`](ricoh_sp230_test_print.prn) | [`ricoh_sp230_emulation.log`](ricoh_sp230_emulation.log) | **PASS** |
| **Ricoh SP 310DN / SP 311** | DDST v1 (Multi-Tray) | `rastertoricohddst` | `ppd/ricoh-sp310.ppd` | [`ricoh_sp310_test_print.prn`](ricoh_sp310_test_print.prn) | [`ricoh_sp310_emulation.log`](ricoh_sp310_emulation.log) | **PASS** |
| **Ricoh SP 200 (Legacy JBIG)** | DDST v1 | `rastertoricohjbig` | `ppd/ricoh-sp200.ppd` | [`ricoh_sp200_legacy_test_print.prn`](ricoh_sp200_legacy_test_print.prn) | [`ricoh_sp200_legacy_emulation.log`](ricoh_sp200_legacy_emulation.log) | **PASS** |

---

## 2. Protocol Architecture

### A. Ricoh DDST v1 (SP 100, 111, 200, 210, 230, 310)
DDST wire captures adhere to the following packet sequence:
1. **Universal Exit Language (UEL)**: `\x1b%-12345X@PJL\r\n`
2. **PJL Job Header**:
   - `@PJL SET TIMESTAMP=YYYY/MM/DD HH:MM:SS`
   - `@PJL SET FILENAME=printjob`
   - `@PJL SET COMPRESS=JBIG`
   - `@PJL SET PAGESTATUS=START`
   - `@PJL SET COPIES=1`
   - `@PJL SET MEDIASOURCE=TRAY1`
   - `@PJL SET DUPLEX=OFF` (or `ON` with `BINDING=LONG|SHORT`)
   - `@PJL SET PAPER=A4`
   - `@PJL SET PAPERWIDTH=4792`
   - `@PJL SET PAPERLENGTH=6850`
   - `@PJL SET RESOLUTION=600`
   - `@PJL SET IMAGELEN=<bytes>`
3. **JBIG Bi-level Image Entity (BIE)**:
   - 20-byte standard BIH (Bi-level Image Header) with options `0x48`, order `0x03`, stripe height `L0=128`.
   - Single-progression entropy-coded bitmap payload.
4. **Trailing Verification & Eject**:
   - `@PJL SET DOTCOUNT=<popcount>`
   - `@PJL SET PAGESTATUS=END`
   - `@PJL EOJ`
   - `\x1b%-12345X\r\n`

### B. Ricoh LHPL (SP 150 Series)
The SP 150 series uses the LHPL protocol:
1. **PJL Language Directive**:
   - `@PJL JOB NAME=PRINTER`
   - `@PJL SET JOBATTR=HST:localhost` ...
   - `@PJL ENTER LANGUAGE=LHPL`
2. **Binary Frame 1 — `@sj` (Start Job)**:
   - 64 bytes prefixed by `\x1bLH@sj\x01\x00`
   - Number of copies (16-bit LE)
   - 1-byte XOR checksum stored at byte 63
3. **Binary Frame 2 — `@sp` (Start Page)**:
   - 64 bytes prefixed by `\x1bLH@sp\x02\x01`
   - Page dimensions: 5120 width x 6978 height (including 128 top pad rows)
   - Uncompressed size, compressed size, 600 DPI, physical paper dimensions (2100 x 2970 in 0.1 mm units)
   - 1-byte XOR checksum stored at byte 63
4. **JBIG-KIT T.85 Bitmap**:
   - Pristine single-progression T.85 JBIG stream with L0=128, SDRST resets, MX=8.
5. **Binary Frame 3 — `@ep` (End Page)**:
   - 64 bytes prefixed by `\x1bLH@ep`
   - 1-byte XOR checksum stored at byte 63
6. **Trailing Cleanup**: `@PJL EOJ\r\n\x1b%-12345X\r\n`

---

## 3. Direct Hardware Printing

You can send any `.prn` test print directly to a physical printer without going through the print dialog:

### Via USB (`/dev/usb/lp0` or `usblp` on Linux)
```bash
# Example: Send SP 200 test page directly to USB printer
sudo cat test_prints/ricoh_sp200_test_print.prn > /dev/usb/lp0

# Example: Send SP 150 test page directly to USB printer
sudo cat test_prints/ricoh_sp150_test_print.prn > /dev/usb/lp0
```

### Via Network (Port 9100 / JetDirect / Raw TCP)
```bash
# Example: Send SP 230 test page to network printer IP 192.168.1.150
nc -w 5 192.168.1.150 9100 < test_prints/ricoh_sp230_test_print.prn
```

### Via CUPS Raw Queue (`lpr -l`)
```bash
lpr -P Ricoh_SP_200_DDST -l test_prints/ricoh_sp200_test_print.prn
```

---

## 4. Re-generating Test Prints & Emulation Logs

To regenerate all test prints and re-run ASIC protocol dissection:
```bash
./test_prints/generate_all.sh
```
Or via the top-level Makefile:
```bash
make test-prints
```

To dissect any arbitrary `.prn` print job file:
```bash
python3 test_prints/dissect_stream.py <path_to_file.prn>
```
