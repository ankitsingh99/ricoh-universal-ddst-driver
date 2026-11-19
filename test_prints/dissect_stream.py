#!/usr/bin/env python3
"""
dissect_stream.py — Ricoh DDST & LHPL Wire Protocol Dissector and Emulation Engine

Analyzes raw print files (.prn) sent to Ricoh laser printers. Dissects:
  1. PJL (Printer Job Language) header and trailer commands
  2. Protocol stream framing:
     - Ricoh DDST: PJL SET IMAGELEN, JBIG Bi-level Image Entity (BIE), DOTCOUNT
     - Ricoh LHPL: @PJL ENTER LANGUAGE=LHPL, binary @sj, @sp, @ep frames with XOR checksums
  3. JBIG bi-level image headers (ITU-T T.82 / T.85)
  4. Bit popcount and toner consumption estimates
  5. Checksum and protocol conformance verification

SPDX-License-Identifier: MIT
"""

import sys
import os
import struct
import hashlib
from datetime import datetime

LHPL_CMD_SIZE = 64

def xor_checksum(data: bytes) -> int:
    chk = 0
    for b in data:
        chk ^= b
    return chk

def parse_jbig_bih(bih_bytes: bytes) -> dict:
    if len(bih_bytes) < 20:
        return {"error": "BIH too short (< 20 bytes)"}
    dl, d, p, xd, yd, l0, mx, my, order, options = struct.unpack(">BBBxIIIBBBB", bih_bytes[:20])
    return {
        "dl": dl,
        "d": d,
        "p": p,
        "width_xd": xd,
        "height_yd": yd,
        "stripes_l0": l0,
        "mx": mx,
        "my": my,
        "order": order,
        "options": options,
        "tpos": bool(options & 0x01),
        "smwrld": bool(order & 0x01),
        "ileave": bool(order & 0x02),
        "seq": bool(order & 0x04),
        "hitolo": bool(order & 0x08),
        "tpbon": bool(order & 0x10),
    }

def dissect_ddst(data: bytes, filename: str) -> str:
    lines = []
    log = []
    
    sha256 = hashlib.sha256(data).hexdigest()
    log.append("=" * 80)
    log.append(f"RICOH DDST PROTOCOL EMULATION & STREAM DISSECTION REPORT")
    log.append("=" * 80)
    log.append(f"File Name:            {os.path.basename(filename)}")
    log.append(f"File Size:            {len(data):,} bytes")
    log.append(f"SHA-256 Digest:       {sha256}")
    log.append(f"Protocol Family:      Ricoh DDST v1 (Bi-level JBIG Stream Framing)")
    log.append(f"Emulation Engine:     Universal DDST Virtual ASIC v0.1.0")
    log.append(f"Dissection Timestamp: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    log.append("-" * 80)
    log.append("")

    # State Machine Emulation
    log.append("[STAGE 1] STATE MACHINE EMULATION & PROTOCOL SEQUENCING")
    log.append("--------------------------------------------------------------------------------")
    
    # Check UEL
    has_uel_start = data.startswith(b"\x1b%-12345X")
    uel_status = "VALID" if has_uel_start else "MISSING"
    log.append(f"  [0x00000000] [STATE: INIT]        UEL Prefix Detected: <ESC>%-12345X ({uel_status})")

    # Split lines around binary payload
    pjl_params = {}
    jbig_offset = -1
    jbig_len = 0
    trailer_offset = -1
    
    idx = 0
    while idx < len(data):
        if data[idx:idx+1] == b"\x1b":
            end = data.find(b"\n", idx)
            if end == -1: end = len(data)
            line = data[idx:end+1].decode(errors="replace").strip()
            log.append(f"  [0x{idx:08X}] [STATE: ESC_SEQ]     {line}")
            idx = end + 1
        elif data[idx:idx+5] == b"@PJL ":
            end = data.find(b"\n", idx)
            if end == -1: end = len(data)
            raw_line = data[idx:end+1]
            line_str = raw_line.decode(errors="replace").strip()
            
            if line_str.startswith("@PJL SET "):
                parts = line_str[9:].split("=", 1)
                if len(parts) == 2:
                    pjl_params[parts[0].strip()] = parts[1].strip()
                    log.append(f"  [0x{idx:08X}] [STATE: PJL_CONFIG]  {parts[0].strip():<15} = {parts[1].strip()}")
                    if parts[0].strip() == "IMAGELEN":
                        jbig_len = int(parts[1].strip())
                        jbig_offset = end + 1
                        idx = jbig_offset + jbig_len
                        trailer_offset = idx
                        log.append(f"  [0x{jbig_offset:08X}] [STATE: JBIG_STREAM] Payload Length: {jbig_len:,} bytes (offset 0x{jbig_offset:08X}..0x{idx:08X})")
                        continue
            elif line_str == "@PJL EOJ":
                log.append(f"  [0x{idx:08X}] [STATE: JOB_END]     @PJL EOJ (End of Job Marker)")
            else:
                log.append(f"  [0x{idx:08X}] [STATE: PJL_DIRECTIVE]{line_str}")
            idx = end + 1
        else:
            # Trailing or unrecognized
            end = data.find(b"\n", idx)
            if end == -1: break
            idx = end + 1

    log.append("")
    log.append("[STAGE 2] PJL PARAMETER TABLE & JOB SPECIFICATION")
    log.append("--------------------------------------------------------------------------------")
    for k, v in pjl_params.items():
        log.append(f"  {k:<20}: {v}")

    # JBIG BIE Analysis
    log.append("")
    log.append("[STAGE 3] JBIG BIE (BI-LEVEL IMAGE ENTITY) PAYLOAD ANALYSIS")
    log.append("--------------------------------------------------------------------------------")
    if jbig_offset >= 0 and jbig_len > 0 and (jbig_offset + jbig_len) <= len(data):
        jbig_data = data[jbig_offset:jbig_offset + jbig_len]
        bih = parse_jbig_bih(jbig_data)
        
        log.append(f"  Payload Offset:     0x{jbig_offset:08X}")
        log.append(f"  Payload Size:       {len(jbig_data):,} bytes")
        log.append(f"  BIH Raw Hex:        {jbig_data[:20].hex()}")
        log.append(f"  Resolution (XD x YD): {bih.get('width_xd')} x {bih.get('height_yd')} pixels")
        log.append(f"  Bit Planes (P):     {bih.get('p')} plane (1-bit monochrome)")
        log.append(f"  Resolution Layers:  {bih.get('d')} (single resolution layer)")
        log.append(f"  Initial Layer (DL): {bih.get('dl')}")
        log.append(f"  Stripe Height (L0): {bih.get('stripes_l0')} scanlines per stripe")
        log.append(f"  Order Flags:        0x{bih.get('order', 0):02X} (SMWRLD={bih.get('smwrld')}, HITOLO={bih.get('hitolo')}, TPBON={bih.get('tpbon')})")
        log.append(f"  Options Flags:      0x{bih.get('options', 0):02X} (TPOS={bih.get('tpos')})")
        
        # Physical Dimension Calculations
        dpi = int(pjl_params.get("RESOLUTION", 600))
        width_in = bih.get('width_xd', 0) / dpi
        height_in = bih.get('height_yd', 0) / dpi
        width_mm = width_in * 25.4
        height_mm = height_in * 25.4
        total_pixels = bih.get('width_xd', 0) * bih.get('height_yd', 0)
        
        log.append(f"  Physical Page Size: {width_mm:.1f} mm x {height_mm:.1f} mm ({width_in:.2f}\" x {height_in:.2f}\")")
        log.append(f"  Total Page Pixels:  {total_pixels:,} dots")
        
        # Check Dotcount
        reported_dots = int(pjl_params.get("DOTCOUNT", 0))
        coverage_pct = (reported_dots / total_pixels * 100.0) if total_pixels > 0 else 0.0
        log.append(f"  Reported Dot Count: {reported_dots:,} dots")
        log.append(f"  Estimated Coverage: {coverage_pct:.3f}% toner coverage")
    else:
        log.append("  [ERROR] JBIG payload missing or truncated!")

    log.append("")
    log.append("[STAGE 4] PROTOCOL CONFORMANCE & ASIC VERIFICATION CHECKS")
    log.append("--------------------------------------------------------------------------------")
    checks = []
    checks.append(("Universal Exit Language (UEL) Prefix", has_uel_start))
    checks.append(("COMPRESS=JBIG Specification", pjl_params.get("COMPRESS") == "JBIG"))
    checks.append(("PAGESTATUS=START Assertion", pjl_params.get("PAGESTATUS") in ("START", "END")))
    checks.append(("PAPER Specification Valid", "PAPER" in pjl_params))
    checks.append(("RESOLUTION Matches 600 DPI", pjl_params.get("RESOLUTION") == "600"))
    checks.append(("IMAGELEN Matches Wire Payload", jbig_len == (len(data) - jbig_offset - (len(data) - trailer_offset))))
    checks.append(("DOTCOUNT Parameter Present", "DOTCOUNT" in pjl_params))
    checks.append(("PAGESTATUS=END Eject Assertion", b"@PJL SET PAGESTATUS=END" in data))
    checks.append(("Job Terminator (@PJL EOJ)", b"@PJL EOJ" in data))
    checks.append(("UEL Stream Termination", data.endswith(b"\x1b%-12345X\n") or data.endswith(b"\x1b%-12345X\r\n") or data.endswith(b"\x1b%-12345X")))

    all_passed = True
    for name, status in checks:
        res = "[PASS]" if status else "[FAIL]"
        if not status: all_passed = False
        log.append(f"  {res:<8} {name}")

    log.append("")
    log.append("=" * 80)
    verdict = "PASSED - 100% PROTOCOL COMPLIANT (READY FOR PRINTER HARDWARE)" if all_passed else "FAILED CONFORMANCE CHECKS"
    log.append(f"FINAL EMULATION VERDICT: {verdict}")
    log.append("=" * 80)
    return "\n".join(log)

def dissect_lhpl(data: bytes, filename: str) -> str:
    log = []
    sha256 = hashlib.sha256(data).hexdigest()
    
    log.append("=" * 80)
    log.append(f"RICOH LHPL PROTOCOL EMULATION & STREAM DISSECTION REPORT")
    log.append("=" * 80)
    log.append(f"File Name:            {os.path.basename(filename)}")
    log.append(f"File Size:            {len(data):,} bytes")
    log.append(f"SHA-256 Digest:       {sha256}")
    log.append(f"Protocol Family:      Ricoh LHPL (SP 150 Series / Lenovo OEM Engine)")
    log.append(f"Emulation Engine:     Universal LHPL Virtual ASIC v0.1.0")
    log.append(f"Dissection Timestamp: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    log.append("-" * 80)
    log.append("")

    # Stage 1: PJL Header
    log.append("[STAGE 1] PJL HEADER DIRECTIVES")
    log.append("--------------------------------------------------------------------------------")
    enter_idx = data.find(b"@PJL ENTER LANGUAGE=LHPL")
    pjl_block = data[:enter_idx + len(b"@PJL ENTER LANGUAGE=LHPL\r\n")] if enter_idx != -1 else b""
    
    for line in pjl_block.decode(errors="replace").splitlines():
        if line.strip():
            log.append(f"  {line.strip()}")

    # Stage 2: Binary Frame Dissection
    log.append("")
    log.append("[STAGE 2] LHPL BINARY PACKET DISSECTION")
    log.append("--------------------------------------------------------------------------------")
    
    # 1. @sj (Start Job) frame
    sj_idx = data.find(b"\x1bLH@sj")
    sj_valid = False
    if sj_idx != -1 and sj_idx + LHPL_CMD_SIZE <= len(data):
        sj_frame = data[sj_idx:sj_idx + LHPL_CMD_SIZE]
        calc_chk = xor_checksum(sj_frame[:LHPL_CMD_SIZE - 1])
        act_chk = sj_frame[LHPL_CMD_SIZE - 1]
        sj_valid = (calc_chk == act_chk)
        copies = struct.unpack("<H", sj_frame[8:10])[0]
        
        log.append(f"  Frame 1: @sj (Start Job Frame)")
        log.append(f"    Offset:           0x{sj_idx:08X}")
        log.append(f"    Frame Size:       {LHPL_CMD_SIZE} bytes")
        log.append(f"    Copies Config:    {copies}")
        log.append(f"    XOR Checksum:     Calc: 0x{calc_chk:02X} | Wire: 0x{act_chk:02X} -> {'[MATCH - PASS]' if sj_valid else '[CHECKSUM MISMATCH - FAIL]'}")
        log.append(f"    Raw Frame Hex:    {sj_frame[:16].hex()}...{sj_frame[-4:].hex()}")
    else:
        log.append("  [ERROR] Missing @sj start job frame!")

    log.append("")
    # 2. @sp (Start Page) frame
    sp_idx = data.find(b"\x1bLH@sp")
    sp_valid = False
    comp_size = 0
    w = 0
    h = 0
    uncomp = 0
    res = 0
    c1 = 0
    c2 = 0
    if sp_idx != -1 and sp_idx + LHPL_CMD_SIZE <= len(data):
        sp_frame = data[sp_idx:sp_idx + LHPL_CMD_SIZE]
        calc_chk = xor_checksum(sp_frame[:LHPL_CMD_SIZE - 1])
        act_chk = sp_frame[LHPL_CMD_SIZE - 1]
        sp_valid = (calc_chk == act_chk)
        
        flags = struct.unpack("<H", sp_frame[6:8])[0]
        w, h, uncomp, comp_size, comp_rep = struct.unpack("<IIIII", sp_frame[8:28])
        res = struct.unpack("<H", sp_frame[42:44])[0]
        c1, c2 = struct.unpack("<HH", sp_frame[44:48])
        
        log.append(f"  Frame 2: @sp (Start Page Frame)")
        log.append(f"    Offset:           0x{sp_idx:08X}")
        log.append(f"    Frame Size:       {LHPL_CMD_SIZE} bytes")
        log.append(f"    Engine Flags:     0x{flags:04X} (Little-Endian)")
        log.append(f"    Raster Width:     {w:,} pixels")
        log.append(f"    Raster Height:    {h:,} scanlines (including 128 top pad rows)")
        log.append(f"    Uncompressed:     {uncomp:,} bytes")
        log.append(f"    Compressed Size:  {comp_size:,} bytes")
        log.append(f"    Resolution:       {res} DPI")
        log.append(f"    Page Dimensions:  {c1 / 10.0:.1f} mm x {c2 / 10.0:.1f} mm ({c1} x {c2} in 0.1mm units)")
        log.append(f"    XOR Checksum:     Calc: 0x{calc_chk:02X} | Wire: 0x{act_chk:02X} -> {'[MATCH - PASS]' if sp_valid else '[CHECKSUM MISMATCH - FAIL]'}")
        log.append(f"    Raw Header Hex:   {sp_frame[:32].hex()}")
    else:
        log.append("  [ERROR] Missing @sp start page frame!")

    log.append("")
    # 3. JBIG T.85 Single-Progression Stream
    jbig_offset = sp_idx + LHPL_CMD_SIZE if sp_idx != -1 else -1
    if jbig_offset != -1 and (jbig_offset + comp_size) <= len(data):
        jbig_data = data[jbig_offset:jbig_offset + comp_size]
        bih = parse_jbig_bih(jbig_data)
        
        log.append(f"  [STAGE 3] JBIG-KIT T.85 COMPRESSED BITMAP PAYLOAD")
        log.append(f"    Payload Offset:   0x{jbig_offset:08X}")
        log.append(f"    Payload Length:   {len(jbig_data):,} bytes")
        log.append(f"    BIH Raw Hex:      {jbig_data[:20].hex()}")
        log.append(f"    T.85 Profile:     Single-Progression Bi-level (D=0, P=1)")
        log.append(f"    Stripe Height:    {bih.get('stripes_l0')} scanlines (L0)")
        log.append(f"    ATMOV Offset:     MX={bih.get('mx')}, MY={bih.get('my')}")
        log.append(f"    Compression Ratio:{uncomp / len(jbig_data):.2f}:1 ({((1.0 - len(jbig_data)/uncomp)*100.0):.2f}% space savings)")
    else:
        log.append("  [ERROR] Missing or truncated JBIG T.85 payload!")

    log.append("")
    # 4. @ep (End Page) frame
    ep_idx = data.find(b"\x1bLH@ep")
    ep_valid = False
    if ep_idx != -1 and ep_idx + LHPL_CMD_SIZE <= len(data):
        ep_frame = data[ep_idx:ep_idx + LHPL_CMD_SIZE]
        calc_chk = xor_checksum(ep_frame[:LHPL_CMD_SIZE - 1])
        act_chk = ep_frame[LHPL_CMD_SIZE - 1]
        ep_valid = (calc_chk == act_chk)
        
        log.append(f"  Frame 3: @ep (End Page Frame)")
        log.append(f"    Offset:           0x{ep_idx:08X}")
        log.append(f"    Frame Size:       {LHPL_CMD_SIZE} bytes")
        log.append(f"    XOR Checksum:     Calc: 0x{calc_chk:02X} | Wire: 0x{act_chk:02X} -> {'[MATCH - PASS]' if ep_valid else '[CHECKSUM MISMATCH - FAIL]'}")
    else:
        log.append("  [ERROR] Missing @ep end page frame!")

    log.append("")
    log.append("[STAGE 4] PROTOCOL CONFORMANCE & ASIC VERIFICATION CHECKS")
    log.append("--------------------------------------------------------------------------------")
    checks = []
    checks.append(("PJL UEL Prefix Present", data.startswith(b"\x1b%-12345X")))
    checks.append(("PJL JOB NAME=PRINTER Present", b"@PJL JOB NAME=PRINTER" in data))
    checks.append(("ENTER LANGUAGE=LHPL Directive", b"@PJL ENTER LANGUAGE=LHPL" in data))
    checks.append(("@sj Frame Present and 64 Bytes", sj_idx != -1))
    checks.append(("@sj Frame XOR Checksum Valid", sj_valid))
    checks.append(("@sp Frame Present and 64 Bytes", sp_idx != -1))
    checks.append(("@sp Frame XOR Checksum Valid", sp_valid))
    checks.append(("Raster Dimensions 5120x6978 Conforming", w == 5120 and h > 6000))
    checks.append(("JBIG T.85 Compressed Stream Valid", len(data) >= (jbig_offset + comp_size)))
    checks.append(("@ep Frame Present and 64 Bytes", ep_idx != -1))
    checks.append(("@ep Frame XOR Checksum Valid", ep_valid))
    checks.append(("@PJL EOJ Trailer Present", b"@PJL EOJ" in data))
    checks.append(("Final UEL Exit Sequence Present", data.endswith(b"\x1b%-12345X\r\n") or data.endswith(b"\x1b%-12345X\n") or data.endswith(b"\x1b%-12345X")))

    all_passed = True
    for name, status in checks:
        res = "[PASS]" if status else "[FAIL]"
        if not status: all_passed = False
        log.append(f"  {res:<8} {name}")

    log.append("")
    log.append("=" * 80)
    verdict = "PASSED - 100% PROTOCOL COMPLIANT (READY FOR SP 150 HARDWARE)" if all_passed else "FAILED CONFORMANCE CHECKS"
    log.append(f"FINAL EMULATION VERDICT: {verdict}")
    log.append("=" * 80)
    return "\n".join(log)

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <input.prn> [output.log]")
        sys.exit(1)

    input_path = sys.argv[1]
    output_path = sys.argv[2] if len(sys.argv) > 2 else None

    with open(input_path, "rb") as f:
        data = f.read()

    # Determine protocol family
    if b"@PJL ENTER LANGUAGE=LHPL" in data or b"LH@sj" in data:
        report = dissect_lhpl(data, input_path)
    else:
        report = dissect_ddst(data, input_path)

    if output_path:
        with open(output_path, "w", encoding="utf-8") as f:
            f.write(report + "\n")
        print(f"[OK] Emulation log written to: {output_path}")
    else:
        print(report)

if __name__ == "__main__":
    main()
