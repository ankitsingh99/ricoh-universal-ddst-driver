# Ricoh Universal DDST/GDI/LHPL Driver Suite — System Design & Technical Architecture

## 1. Executive Summary & Purpose

The **Ricoh Universal DDST/GDI/LHPL CUPS Driver Suite** is a modular, high-performance native raster filter, network print server, and Adobe-compliant PostScript Printer Description (PPD) driver system. It supports Ricoh DDST (Device Driver String Translation), host-based GDI, and Ricoh LHPL (Low-End Host-based Page Language) monochrome laser and multifunction printers on **Linux** (Debian, Ubuntu, Fedora, openSUSE, Arch, Alpine, Void, Gentoo), **FreeBSD**, **OpenBSD**, **NetBSD**, **DragonFly BSD**, **macOS** (Apple Silicon M1/M2/M3/M4 & Intel x86_64), and **Solaris/illumos**.

Ricoh consumer and workgroup laser printers are host-based ("GDI") devices that lack on-board PostScript (PS) or PCL interpreters. Instead of rendering page description languages in hardware, they require the host operating system to rasterize documents into 1-bit monochrome bitmaps, compress the pixels, and encapsulate the payload within hardware-specific framing sequences:
- **DDST Engines (SP 100, 111, 200, 210, 230, 310 series)**: Encapsulate compressed raster data in ITU-T T.82 JBIG1 format with HP-PJL directives (`@PJL SET COMPRESS=JBIG`, `IMAGELEN`, and hardware `DOTCOUNT` popcounts).
- **LHPL Engines (SP 150 series, Lenovo M100D/L100D OEM)**: Encapsulate compressed raster data in pristine ITU-T T.85 single-progression JBIG format wrapped in fixed 64-byte binary packet frames (`@sj`, `@sp`, `@ep`) verified with 1-byte XOR checksums.

This document details the complete end-to-end architecture, protocol reverse-engineering findings, hardware model extrapolation, network/mobile printing subsystem (AirPrint & IPP), spool queue state machines, sandboxing models, and validation strategies.

---

## 2. High-Level System Architecture

The following diagram illustrates the complete data flow from application clients (desktop, mobile, cloud) through the universal GDI raster layer and dispatching into the native DDST or LHPL filter:

```mermaid
flowchart TD
    subgraph Clients["Client Tier"]
        iOS["iOS Device\n(Apple AirPrint)"]
        Android["Android Device\n(Default Print / Mopria)"]
        Desktop["macOS / Linux / Windows\n(Native Application)"]
    end

    subgraph Discovery["Network Service Discovery Tier"]
        mDNS["mDNSResponder (macOS) / Avahi (Linux)\n_ipp._tcp, _universal._sub._ipp._tcp\n(Port 631, URF=none, pdl=application/pdf)"]
        LaunchAgent["LaunchAgent / Avahi Daemon\ncom.ricoh.airprint.plist\n(Persistent Background Broadcast)"]
    end

    subgraph Spooler["CUPS Printing & Spooling Engine"]
        IPP["CUPS IPP Listener\n(http://0.0.0.0:631/printers/...)"]
        SpoolQueue["Spool Queue Storage\n(/var/spool/cups/)\nErrorPolicy: retry-current-job"]
        FilterPipeline["CUPS Filter Chain"]
        PDFtoRaster["cgpdftoraster (macOS) / pdftoraster (Linux)\nMIME: application/vnd.cups-raster"]
    end

    subgraph DriverFilter["Universal Driver Filter Tier"]
        subgraph DDST_Branch["DDST Filter: rastertoricohddst"]
            DDST_Hdr["cupsRasterReadHeader2"]
            DDST_Color["Color Conversion (Gray/RGB -> 1-bit)"]
            DDST_Pop["64-bit Hardware Popcount Engine"]
            DDST_JBIG["ITU-T T.82 JBIG1 Compressor"]
            DDST_PJL["PJL & DDST Wire Stream Builder"]
        end

        subgraph LHPL_Branch["LHPL Filter: rastertoricohlhpl"]
            LHPL_Hdr["cupsRasterReadHeader2"]
            LHPL_Pad["128-Row Blank Top Margin Padding"]
            LHPL_Bayer["Bayer 8x8 Ordered Halftoning Engine"]
            LHPL_T85["Vendored JBIG-KIT T.85 Compressor"]
            LHPL_Frames["64-Byte Binary Framing (@sj/@sp/@ep, XOR)"]
        end
    end

    subgraph Backend["I/O Backend & Hardware Tier"]
        USBBackend["CUPS USB Backend\n(/usr/libexec/cups/backend/usb)"]
        IOKit["macOS IOKit / Linux usblp & libusb"]
        PrinterDDST["Physical Ricoh DDST Printer\n(SP 100/111/200/210/230/310)"]
        PrinterLHPL["Physical Ricoh LHPL Printer\n(SP 150 Series, Lenovo M100D)"]
    end

    iOS -->|mDNS Query| mDNS
    Android -->|mDNS Query| mDNS
    LaunchAgent -.->|Registers Service| mDNS

    iOS -->|IPP POST: PDF/Image| IPP
    Android -->|IPP POST: PDF| IPP
    Desktop -->|Local IPC / lpr| SpoolQueue

    IPP --> SpoolQueue
    SpoolQueue --> FilterPipeline
    FilterPipeline --> PDFtoRaster
    PDFtoRaster -->|application/vnd.cups-raster| DDST_Hdr
    PDFtoRaster -->|application/vnd.cups-raster| LHPL_Hdr

    DDST_Hdr --> DDST_Color --> DDST_Pop --> DDST_JBIG --> DDST_PJL
    DDST_PJL -->|stdout: DDST Wire Stream| USBBackend

    LHPL_Hdr --> LHPL_Pad --> LHPL_Bayer --> LHPL_T85 --> LHPL_Frames
    LHPL_Frames -->|stdout: LHPL Wire Stream| USBBackend

    USBBackend --> IOKit
    IOKit -->|USB Bulk Endpoint| PrinterDDST
    IOKit -->|USB Bulk Endpoint| PrinterLHPL
```

---

## 3. Print Subsystem & Filter Pipeline

CUPS processes all documents via a pipelined filter architecture coordinated by MIME typing and PPD declarations.

### 3.1 PPD & Filter Binding
Each supported printer model is assigned a PostScript Printer Description file (in `ppd/*.ppd`). The PPD defines:
```postscript
*cupsVersion: 2.0
*cupsFilter: "application/vnd.cups-raster 0 rastertoricohddst"
```
On macOS, due to sandbox restrictions, this path is rewritten during installation to an absolute path:
```postscript
*cupsFilter: "application/vnd.cups-raster 0 /Library/Printers/Ricoh/Filter/rastertoricohddst"
```

### 3.2 Inbound Stream Parsing (`cupsRasterReadHeader2`)
The filter opens the raster stream via file descriptor 0 (`stdin`) or argument 6:
```c
cups_raster_t* ras = cupsRasterOpen(fd, CUPS_RASTER_READ);
cups_page_header2_t hdr;
while (cupsRasterReadHeader2(ras, &hdr)) { ... }
```
Extracted metadata includes:
- **Geometry**: `cupsWidth`, `cupsHeight`, `cupsBytesPerLine`.
- **Resolution**: `HWResolution[0]` (e.g., 600 DPI, 1200 DPI).
- **Color Depth**: `cupsBitsPerPixel` (1, 8, 24, or 32 bpp).
- **Color Space**: `cupsColorSpace` (CUPS_CSPACE_K, CUPS_CSPACE_W, CUPS_CSPACE_RGB).
- **Media Specs**: `PageSize` (A4, Letter, Legal), `MediaPosition` (Tray 1 vs Manual Feed).
- **Duplex & Tumble**: `Duplex` (boolean), `Tumble` (short vs long edge binding).

### 3.3 Color & Luminance Conversion Engine
While CUPS rasterizes monochrome jobs to 1-bit natively, mobile devices and certain PDF rasterizers deliver 8-bit Grayscale or 24-bit sRGB streams. `rastertoricohddst` implements an optimized in-memory thresholding and dithering conversion engine:

1. **8-bit Grayscale Thresholding**:
   $$\text{Pixel}_{\text{mono}} = \begin{cases} 1 (\text{Black}), & \text{if } P_{8} < 128 \\ 0 (\text{White}), & \text{if } P_{8} \ge 128 \end{cases}$$
   *(Inverted if `cupsColorSpace == CUPS_CSPACE_K`)*.

2. **24-bit sRGB to Monochrome Luminance**:
   Applies integer ITU-R BT.601 perceptual luminance weights:
   $$Y = \frac{77 \cdot R + 150 \cdot G + 29 \cdot B}{256}$$
   $$\text{Pixel}_{\text{mono}} = \begin{cases} 1 (\text{Black}), & \text{if } Y < 128 \\ 0 (\text{White}), & \text{if } Y \ge 128 \end{cases}$$

Bits are packed MSB-first into a byte-aligned stride:
```c
acc = (unsigned char)((acc << 1) | (black ? 1 : 0));
```

### 3.4 High-Speed 64-Bit Hardware Popcount Engine (`count_dots`)
The Ricoh hardware engine requires an accurate count of all printed dots per page passed via `@PJL SET DOTCOUNT=...`. The engine uses this value to measure toner consumption, maintain electrostatic charge balance, and manage the waste toner counter.

To avoid performance degradation on large rasters (e.g., 1200x600 DPI Legal size containing > 67 million pixels), `rastertoricohddst` employs hardware 64-bit popcount intrinsics:
```c
STATIC unsigned long count_dots(const unsigned char* bmp, unsigned w, unsigned h)
{
    unsigned stride = (w + 7) / 8;
    size_t total_bytes = (size_t)stride * h;
    size_t u64_count = total_bytes / sizeof(uint64_t);
    const uint64_t* p64 = (const uint64_t*)(const void*)bmp;
    unsigned long n = 0;

    for (size_t i = 0; i < u64_count; i++) {
        n += (unsigned long)__builtin_popcountll(p64[i]);
    }

    const unsigned char* p8 = bmp + u64_count * sizeof(uint64_t);
    for (size_t i = 0; i < total_bytes % sizeof(uint64_t); i++) {
        n += (unsigned long)__builtin_popcount(p8[i]);
    }
    return n;
}
```
This processes 64 pixels per CPU cycle on modern ARM64 and x86_64 architectures.

---

## 4. Reverse-Engineered Wire Protocol & PJL Framing

The wire stream sent to the Ricoh USB endpoint is an encapsulated hybrid stream combining HP-PJL and JBIG1 Bi-level Image Entity (BIE) data.

### 4.1 Job Preamble
```text
\x1b%-12345X@PJL\r\n
@PJL SET TIMESTAMP=YYYY/MM/DD HH:MM:SS\r\n
@PJL SET FILENAME=printjob\r\n
@PJL SET COMPRESS=JBIG\r\n
@PJL SET USERNAME=lp\r\n
@PJL SET COVER=OFF\r\n
@PJL SET HOLD=OFF\r\n
@PJL SET PAGESTATUS=START\r\n
@PJL SET COPIES=1\r\n
@PJL SET MEDIASOURCE=TRAY1\r\n
@PJL SET MEDIATYPE=PLAINRECYCLE\r\n
@PJL SET DUPLEX=OFF\r\n
```

### 4.2 Page Header
Each page begins with its geometry parameters:
```text
@PJL SET PAPER=A4\r\n
@PJL SET PAPERWIDTH=4760\r\n
@PJL SET PAPERLENGTH=6736\r\n
@PJL SET RESOLUTION=600\r\n
@PJL SET IMAGELEN=<LengthOfCompressedBIEInBytes>\r\n
```

### 4.3 JBIG1 Compression (ITU-T T.82)
The compressed binary BIE payload follows immediately after `@PJL SET IMAGELEN=...`.
- Encoded using `libjbig` (`jbg_enc_init` and `jbg_enc_options`).
- **Options**: `0x48` (`JBG_HITOLO | JBG_VLENGTH`).
- **Order**: `0x03` (`JBG_ILEAVE | JBG_SMID`).
- **Lines Per Stripe (LDP)**: `128`.

### 4.4 Page Trailer & Paper Eject
Immediately following the raw BIE byte sequence:
```text
@PJL SET DOTCOUNT=<PopcountBlackPixels>\r\n
@PJL SET PAGESTATUS=END\r\n
```
The printer firmware requires both `@PJL SET DOTCOUNT` and `@PJL SET PAGESTATUS=END` to actuate the paper feed mechanism and eject the sheet.

### 4.5 Job Epilogue (DDST)
```text
@PJL EOJ\r\n
\x1b%-12345X\r\n
```
The Universal Exit Language sequence (`\x1b%-12345X`) resets the printer's command parser back to idle standby.

### 4.6 Ricoh LHPL Protocol Architecture (`rastertoricohlhpl`)

The Ricoh SP 150 series and compatible OEM engines (e.g. Lenovo M100D, L100D) employ the **LHPL (Low-End Host-based Page Language)** wire protocol instead of DDST:

1. **PJL Language Switch**:
   ```text
   \x1b%-12345X@PJL JOB NAME=PRINTER\r\n
   @PJL SET JOBATTR=HST:localhost\r\n
   @PJL SET JOBATTR=USR:user\r\n
   @PJL SET JOBATTR=DOC:document\r\n
   @PJL SET RESOLUTION=600\r\n
   @PJL ENTER LANGUAGE=LHPL\r\n
   ```

2. **64-Byte Binary Packet Framing**:
   Every command is framed in a fixed 64-byte packet terminated by a 1-byte XOR checksum over bytes 0..62:
   - **`@sj` (Start Job)**: Prefix `\x1bLH@sj\x01\x00`, 16-bit little-endian copies count at offset 8, byte 63 checksum.
   - **`@sp` (Start Page)**: Prefix `\x1bLH@sp\x02\x01`, contains 32-bit LE width (5120), height (6978 including 128 top pad scanlines), uncompressed size in bytes, compressed JBIG length, 16-bit LE resolution (600 DPI) at byte 42, and paper dimensions $210.0\,\text{mm} \times 297.0\,\text{mm}$ in 0.1 mm units (`0x0834`, `0x0b9a`).
   - **`@ep` (End Page)**: Prefix `\x1bLH@ep`, byte 63 checksum.

3. **Pristine JBIG-KIT T.85 Encoding**:
   Unlike DDST's multi-resolution T.82 encoding, LHPL mandates ITU-T T.85 single-progression compression with:
   - Fixed stripe height $L_0 = 128$ scanlines.
   - Reset markers (`SDRST`) enabled per stripe.
   - Maximal horizontal adaptive template offset $MX = 8$.
   - A mandatory 128-scanline blank top margin to prevent engine feed timing desynchronization.

4. **Trailer**:
   ```text
   @PJL EOJ\r\n
   \x1b%-12345X\r\n
   ```

---

## 5. Mobile & Network Printing Subsystem (AirPrint & IPP)

### 5.1 The Mobile Printing Challenge
Standard consumer and office laser printers attached via USB cannot be discovered by smartphones because mobile operating systems (iOS and Android) only discover print devices over Wi-Fi via Multicast DNS (Bonjour / mDNS). Furthermore:
1. **iOS AirPrint Requirements**: Apple devices require specific mDNS TXT keys (`URF`, `pdl`, `rp`) and DNS-SD service subtypes (`_universal._sub._ipp._tcp`). If these are missing, the printer will not appear in the iOS print sheet.
2. **Offline Vulnerability**: Standard CUPS queues pause (`printer-state=stopped`) when a print job fails due to an offline or disconnected USB printer. If a user prints from their phone while the printer is off, standard queues stop accepting further jobs and require manual administrator intervention to resume.

### 5.2 System Design of the Mobile Printing Engine

```mermaid
sequenceDiagram
    autonumber
    actor Mobile as Mobile Device (iPhone/Android)
    participant mDNS as mDNS / Bonjour (Port 5353)
    participant CUPS as CUPS Scheduler (Port 631)
    participant Queue as Disk Spooler (/var/spool/cups)
    participant USB as USB Backend
    actor Hardware as Ricoh Printer (Powered Off)

    Note over Mobile,Hardware: Phase 1: 24/7 Discovery (Printer Offline)
    Mobile->>mDNS: Multicast DNS Query (_ipp._tcp)
    mDNS-->>Mobile: "Ricoh SP 200 (AirPrint)" (Ashish-Macbook.local:631)
    Note over Mobile: Printer visible in print menu 24/7

    Note over Mobile,Hardware: Phase 2: Spooling Job While Offline
    Mobile->>CUPS: IPP Print-Job Request (POST PDF document)
    CUPS->>Queue: Spool document as Job #30
    CUPS-->>Mobile: IPP 200 OK (status: pending)
    CUPS->>USB: Attempt USB open (usb://RICOH/...)
    USB-->>CUPS: Device offline / disconnected
    Note over CUPS,Queue: ErrorPolicy: retry-current-job<br/>Queue remains ACTIVE & IDLE.<br/>Job held safely on disk.

    Note over Mobile,Hardware: Phase 3: Hotplug & Automatic Printing
    actor User as User
    User->>Hardware: Turn Power ON & Connect USB
    USB->>CUPS: IOKit USB Attached Event (T564M101838)
    CUPS->>Queue: Fetch pending Job #30
    CUPS->>CUPS: Execute filter chain (PDF -> raster -> DDST)
    CUPS->>USB: Stream DDST / JBIG bytes
    USB->>Hardware: Print Document
    Hardware-->>User: Document Printed
```

### 5.3 Persistent mDNS Discovery Daemon
The script [enable_network_printing.sh](file:///Users/ashish/git/Ricoh-SP200-Linux/enable_network_printing.sh) registers a persistent background daemon:
- **macOS LaunchAgent**: Installed to `~/Library/LaunchAgents/com.ricoh.airprint.plist`. Runs `/usr/bin/dns-sd` continuously, surviving reboots and terminal exits.
- **Linux Avahi Service**: Installed to `/etc/avahi/services/ricoh-airprint.service`.

**TXT Record Specifications**:
```text
Service Name:  <Printer Model> (AirPrint)
Service Type:  _ipp._tcp, _universal
Port:          631
TXT Records:
  txtvers=1
  qtotal=1
  rp=printers/<QueueName>
  ty=<ModelName>
  adminurl=http://<HostName>.local:631/printers/<QueueName>
  pdl=application/pdf,image/jpeg
  URF=none
  air=none
```

### 5.4 Offline Spooling & Error Recovery Policy
To guarantee jobs wait on disk when the printer is off or unplugged:
```bash
lpadmin -p <QueueName> -o printer-is-shared=true -o printer-error-policy=retry-current-job
```
- **`retry-current-job`**: Prevents CUPS from stopping or pausing the queue when the USB backend fails to connect. The queue remains `enabled` and `idle/processing`, continuing to accept subsequent jobs from network devices.
- **`printer-is-shared=true`**: Tells the CUPS scheduler to expose the queue over IPP.
- **`cupsctl --share-printers --remote-any`**: Allows incoming TCP connections on port 631 from all IP subnets (2.4GHz Wi-Fi, 5GHz Wi-Fi, Ethernet).

---

## 6. Hardware Model Support & Extrapolation Matrix

| Series | Models | Max Resolution | Duplex | Trays | Supported PPD |
|---|---|---|---|---|---|
| **SP 100** | SP 100, 100e, 100SU, 100SF | 600 DPI | Manual | Tray 1 | `ppd/ricoh-sp100.ppd` |
| **SP 110** | SP 110, 111, 112, SU, SF | 1200x600 DPI | Manual | Tray 1, Manual | `ppd/ricoh-sp111.ppd` |
| **SP 150** | SP 150, 150w, 150SU, 150SUw | 600 DPI | Manual | Tray 1 | `ppd/ricoh-sp150.ppd` (LHPL) |
| **SP 200** | SP 200, 201N/NW, 202, 203, 204 | 1200x600 DPI | Manual | Tray 1, Manual | `ppd/ricoh-sp200.ppd` |
| **SP 210** | SP 210, 211, 212, 213, 220 | 1200x600 DPI | Manual | Tray 1, Manual | `ppd/ricoh-sp210.ppd` |
| **SP 230** | SP 230DNw, 230SFNw | 1200x600 DPI | Auto Duplex | Tray 1, Manual | `ppd/ricoh-sp230.ppd` |
| **SP 310** | SP 310DN, 311DN/SFN, 325, 3710 | 1200x600 DPI | Auto Duplex | Tray 1, Tray 2, Manual | `ppd/ricoh-sp310.ppd` |

---

## 7. Security, Sandboxing & OS Integration

### 7.1 macOS Sandboxing Architecture
macOS executes CUPS filters inside a tightly constrained sandbox environment (`sandbox-exec` / `seatbelt`).
1. **Directory Restrictions**: Custom filters located in `/usr/local/bin` or user home folders fail to execute due to sandbox denial. All binaries must reside in:
   `/Library/Printers/Ricoh/Filter/rastertoricohddst`
2. **File Ownership**: Binaries must be owned by `root:wheel` with permissions `0755`.
3. **Quarantine Bit**: Downloaded or compiled binaries must have the macOS quarantine extended attribute cleared:
   ```bash
   xattr -d com.apple.quarantine /Library/Printers/Ricoh/Filter/rastertoricohddst
   ```

### 7.2 Linux Standard Layout
On Linux, filters and PPDs adhere to the Filesystem Hierarchy Standard (FHS):
- Filter Directory: `/usr/lib/cups/filter/`
- PPD Directory: `/usr/share/ppd/cupsfilters/`

---

## 8. Quality Assurance, Test Suite & CI/CD

### 8.1 Testing Architecture
The codebase includes an automated test framework:

```
tests/
├── generate_test_raster.c   # Synthetic CUPS raster stream generator (10 scenarios)
├── test_mocks.c             # Mock allocator & system time override
├── test_unit_ddst.c         # Unit tests for rastertoricohddst (error injection & logic)
├── test_unit_jbig.c         # Unit tests for rastertoricohjbig
├── test_network_printing.sh # End-to-end IPP, AirPrint, and queue policy tests
└── run_coverage.sh          # gcov line coverage harness (enforces >= 95%)
```

### 8.2 Test Execution Commands
- **Unit & Coverage Suite**:
  ```bash
  make test-coverage
  ```
  Enforces a strict ≥ 95.0% line coverage assertion across both driver filters.
- **Network & Mobile Printing Integration Suite**:
  ```bash
  make test-network
  ```
  Validates live CUPS socket binding, queue retention, and IPP document submission.

### 8.3 Continuous Integration (GitHub Actions)
Every commit and pull request triggers `.github/workflows/ci.yml` across:
- `ubuntu-latest`
- `macos-latest`

Steps executed in CI:
1. PPD validation via `cupstestppd -W filters`.
2. Shell syntax verification via `bash -n`.
3. Test suite execution with `gcov` line coverage assertion (≥ 95%).
4. Strict compilation check (`CFLAGS="-O2 -Wall -Wextra -Werror"`).
5. Native installer package generation (`.pkg` on macOS, `.deb` on Linux).
