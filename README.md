# Ricoh Universal DDST/GDI CUPS Driver Suite (macOS and Linux)

[![CI](https://github.com/ankitsingh99/ricoh-universal-ddst-driver/actions/workflows/ci.yml/badge.svg)](https://github.com/ankitsingh99/ricoh-universal-ddst-driver/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/ankitsingh99/ricoh-universal-ddst-driver?color=blue)](https://github.com/ankitsingh99/ricoh-universal-ddst-driver/releases)
[![Discussions](https://img.shields.io/badge/Discussions-Community%20Q%26A-orange.svg)](https://github.com/ankitsingh99/ricoh-universal-ddst-driver/discussions)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux-blue.svg)](#supported-operating-systems)
[![CUPS Version](https://img.shields.io/badge/CUPS-2.0%2B-blue.svg)](#prerequisites--dependencies)

A native, high-performance CUPS raster filter and Adobe-compliant PPD driver suite for **Ricoh DDST/GDI monochrome laser and multifunction printers** on **macOS** (Apple Silicon M1/M2/M3/M4 & Intel x86_64) and **Linux**.

Consumer and SMB Ricoh DDST/GDI printers lack official Linux and macOS drivers and are absent from standard printer stacks (`foo2zjs`, OpenPrinting, Gutenprint, HPLIP). This project provides a direct native C implementation of the PJL + ITU-T T.82 JBIG1 wire protocol reverse-engineered from USB traffic.

---

> [!IMPORTANT]
> **Hardware Testing & Model Support Status**
> - **Tested Hardware**: This driver has been physically tested and verified with the **Ricoh SP 200** printer.
> - **Extrapolated Models**: Support for other models (SP 100, SP 110/111/112, SP 150, SP 210, SP 230, and SP 310 series) has been **extrapolated** from DDST protocol specifications and reverse-engineered packet captures, but has **not yet been physically tested on those individual models** by the maintainer.
> - **Community Testing & Discussions**: If you use this driver with other Ricoh models and encounter any issues or errors, please [**Open a Discussion on GitHub**](https://github.com/ankitsingh99/ricoh-universal-ddst-driver/discussions) or submit an issue so we can help and refine compatibility.
> - **Contributions**: Community contributions (hardware verification reports, USB packet captures, and pull requests) are warmly welcomed!

> [!NOTE]
> **AI Usage Notice**: This project utilized Artificial Intelligence (AI) assistance for protocol analysis, codebase modernization, and multi-model feature extrapolation.

---

## Supported Printers & Hardware Matrix

| Series Family | Supported Models | PPD Profile | Max Resolution | Duplex / Trays |
|---|---|---|---|---|
| **Ricoh SP 100 Series** | SP 100, SP 100e, SP 100SU, SP 100SF | [`ppd/ricoh-sp100.ppd`](ppd/ricoh-sp100.ppd) | 600 DPI | Manual |
| **Ricoh SP 110 Series** | SP 110, SP 111, SP 112 (incl. SU/SF) | [`ppd/ricoh-sp111.ppd`](ppd/ricoh-sp111.ppd) | 1200x600 DPI | Manual |
| **Ricoh SP 150 Series** | SP 150, SP 150w, SP 150SU, SP 150SUw | [`ppd/ricoh-sp150.ppd`](ppd/ricoh-sp150.ppd) | 1200x600 DPI | Manual |
| **Ricoh SP 200 Series** | SP 200, SP 201N/NW, SP 202, SP 203, SP 204S/SF | [`ppd/ricoh-sp200.ppd`](ppd/ricoh-sp200.ppd) | 1200x600 DPI | Manual |
| **Ricoh SP 210 Series** | SP 210, SP 211, SP 212, SP 213, SP 220 | [`ppd/ricoh-sp210.ppd`](ppd/ricoh-sp210.ppd) | 1200x600 DPI | Manual |
| **Ricoh SP 230 Series** | SP 230DNw, SP 230SFNw | [`ppd/ricoh-sp230.ppd`](ppd/ricoh-sp230.ppd) | 1200x600 DPI | Auto Duplex |
| **Ricoh SP 310 / 325 / 3710** | SP 310DN, SP 311DN/SFN, SP 325, SP 3710 | [`ppd/ricoh-sp310.ppd`](ppd/ricoh-sp310.ppd) | 1200x600 DPI | Auto Duplex + Multi-Tray |
| **OEM Clones** | Equivalent Gestetner, Lanier, Savin, Nashuatec models | Matching PPD | Match Base | Match Base |

---

## Supported Operating Systems

- **macOS**: macOS Sonoma, Ventura, Monterey, Big Sur (Apple Silicon M1/M2/M3/M4 & Intel x86_64)
- **Linux**: Debian, Ubuntu, Linux Mint, Raspberry Pi OS (ARM32/ARM64), Fedora, RHEL, AlmaLinux, Arch Linux, Manjaro

---

## Pre-Built Packages & Installation Methods

Pre-compiled binary packages and standalone installers are available for every release on the [**GitHub Releases Page**](https://github.com/ankitsingh99/ricoh-universal-ddst-driver/releases).

### Option A: macOS Installer Package (`.pkg`)
Download the `.pkg` installer from [Releases](https://github.com/ankitsingh99/ricoh-universal-ddst-driver/releases) and double-click to install, or install via Terminal:
```bash
sudo installer -pkg ricoh-universal-ddst-driver-<version>-macOS.pkg -target /
```

### Option B: Debian / Ubuntu Package (`.deb`)
Download the `.deb` package for your architecture and install:
```bash
sudo dpkg -i ricoh-universal-ddst-driver_<version>_amd64.deb
sudo apt-get install -f
```

### Option C: Standalone Release Tarball (`.tar.gz`)
Download the pre-compiled binary tarball for your platform, extract, and run the automated setup:
```bash
tar -xzf ricoh-universal-ddst-driver-<version>-<os>-<arch>.tar.gz
cd ricoh-universal-ddst-driver-<version>-<os>-<arch>
./setup.sh
```

---

## Step-by-Step Source Build & Configuration Guide

### Method 1: Automated Source Setup

1. Connect your Ricoh printer via USB and power it ON.
2. Clone the repository and execute `./setup.sh`:
   ```bash
   git clone https://github.com/ankitsingh99/ricoh-universal-ddst-driver.git
   cd ricoh-universal-ddst-driver
   chmod +x setup.sh test_print.sh uninstall.sh
   ./setup.sh
   ```
3. The script will automatically detect your OS, install dependencies, compile the filter, install all PPD profiles, detect your connected Ricoh model, and register the print queue.

---

### Method 2: Manual Setup for a Specific Model

#### Step 1: Install Driver Binaries & PPD Library
```bash
sudo make install
```

#### Step 2: Discover Your Printer's Device URI
- **USB Discovery (macOS)**:
  ```bash
  /usr/libexec/cups/backend/usb | grep -i ricoh
  ```
- **USB Discovery (Linux)**:
  ```bash
  lpinfo -v | grep -i ricoh
  ```
  *(Example output: `direct usb://RICOH/SP%20210%20DDST?serial=ABC123`)*

- **Network / Wi-Fi Printers**:
  Use standard raw Port 9100 socket:
  ```text
  socket://<printer-ip-address>:9100
  ```

#### Step 3: Select the PPD Profile for Your Model

| Printer Model | macOS Installed PPD Path | Linux Installed PPD Path |
|---|---|---|
| **SP 100 / SP 100SU / SP 100SF** | `/Library/Printers/PPDs/Contents/Resources/ricoh-sp100.ppd` | `/usr/share/ppd/cupsfilters/ricoh-sp100.ppd` |
| **SP 110 / SP 111 / SP 112** | `/Library/Printers/PPDs/Contents/Resources/ricoh-sp111.ppd` | `/usr/share/ppd/cupsfilters/ricoh-sp111.ppd` |
| **SP 150 / SP 150w / SP 150SU** | `/Library/Printers/PPDs/Contents/Resources/ricoh-sp150.ppd` | `/usr/share/ppd/cupsfilters/ricoh-sp150.ppd` |
| **SP 200 / SP 201 / SP 204** | `/Library/Printers/PPDs/Contents/Resources/ricoh-sp200.ppd` | `/usr/share/ppd/cupsfilters/ricoh-sp200.ppd` |
| **SP 210 / SP 212 / SP 213 / SP 220** | `/Library/Printers/PPDs/Contents/Resources/ricoh-sp210.ppd` | `/usr/share/ppd/cupsfilters/ricoh-sp210.ppd` |
| **SP 230DNw / SP 230SFNw** | `/Library/Printers/PPDs/Contents/Resources/ricoh-sp230.ppd` | `/usr/share/ppd/cupsfilters/ricoh-sp230.ppd` |
| **SP 310 / SP 311 / SP 325 / SP 3710** | `/Library/Printers/PPDs/Contents/Resources/ricoh-sp310.ppd` | `/usr/share/ppd/cupsfilters/ricoh-sp310.ppd` |

#### Step 4: Register & Enable the Print Queue
```bash
# Example for Ricoh SP 210 on macOS:
QUEUE_NAME="Ricoh_SP_210_DDST"
DEVICE_URI="usb://RICOH/SP%20210%20DDST"
PPD_PATH="/Library/Printers/PPDs/Contents/Resources/ricoh-sp210.ppd"

sudo lpadmin -p "$QUEUE_NAME" -v "$DEVICE_URI" -P "$PPD_PATH" -E
sudo cupsenable "$QUEUE_NAME"
sudo cupsaccept "$QUEUE_NAME"
```

#### Step 5: Send a Test Print
```bash
echo "Test print from Ricoh Driver" | lpr -P "$QUEUE_NAME"
```

---

### Method 3: Via the CUPS Web Interface / GUI

Once you run `sudo make install`:
1. Open your browser: **[http://localhost:631](http://localhost:631)**
2. Go to **Administration** -> **Add Printer**.
3. Select your detected USB / Network Ricoh printer.
4. Under **Manufacturer**, select **Ricoh**.
5. Select your specific model (e.g., *Ricoh SP 111 DDST*, *Ricoh SP 210 DDST*, *Ricoh SP 310 DDST*).
6. Click **Add Printer** and set default options.

---

## Prerequisites & Dependencies

### macOS (Homebrew)
```bash
brew install cups jbigkit ghostscript
```

### Debian / Ubuntu / Linux Mint / Raspberry Pi OS
```bash
sudo apt update
sudo apt install -y libcups2-dev libcupsimage2-dev libjbig-dev jbigkit-bin gcc ghostscript cups cups-client
```

### Fedora / RHEL / AlmaLinux
```bash
sudo dnf install -y cups-devel cups-libs jbigkit-devel jbigkit-libs gcc ghostscript
```

### Arch Linux / Manjaro
```bash
sudo pacman -S --needed cups ghostscript jbigkit gcc
```

---

## Troubleshooting Guide

### 1. File ".../rastertoricohddst" has insecure permissions (0100755/uid=501)
- **Cause**: On macOS, CUPS rejects filters located in user directories or Homebrew directories due to sandbox security.
- **Solution**: Run `sudo make install` or set root ownership:
  ```bash
  sudo chown -R root:wheel /Library/Printers/Ricoh
  sudo chmod 755 /Library/Printers/Ricoh/Filter/rastertoricohddst
  ```

### 2. Printer status shows Offline or Not Responding
- **Apple Silicon Accessory Prompt**: On macOS Ventura/Sonoma/Sequoia, check for the prompt **"Allow accessory to connect?"** or enable it in **System Settings -> Privacy & Security -> Allow accessories to connect**.
- **Check USB Connection**:
  - macOS: `/usr/libexec/cups/backend/usb`
  - Linux: `lsusb` and `lpinfo -v | grep -i ricoh`

### 3. Clearing Stuck Jobs
```bash
cancel -a
```

---

## Architecture & Technical Protocol

```
                  +-----------------------------------------------------------+
                  |                 CUPS Print Framework                      |
                  |        (Input: application/vnd.cups-raster)                |
                  +-----------------------------+-----------------------------+
                                                |
                                                v
                  +-----------------------------------------------------------+
                  |          rastertoricohddst (Native C Filter)              |
                  +-----------------------------------------------------------+
                  | 1. Model Profile & PPD parser (Tray, Duplex, Resolution)  |
                  | 2. Color Conversion Engine (1-bit Monochrome)             |
                  | 3. ITU-T T.82 JBIG1 Compression via libjbig               |
                  | 4. PJL Stream Builder & Dynamic Dot Counter               |
                  +-----------------------------+-----------------------------+
                                                |
                                                v
                  +-----------------------------------------------------------+
                  |          USB / Network (IPP / AppSocket) Backend          |
                  |                   Ricoh Laser Printer                     |
                  +-----------------------------------------------------------+
```

---

| File / Directory | Description |
|---|---|
| [`rastertoricohddst.c`](rastertoricohddst.c) | Native universal C source code for Ricoh DDST filter |
| [`rastertoricohjbig.c`](rastertoricohjbig.c) | Legacy SP 200 filter (maintained for backward compatibility) |
| [`ppd/`](ppd/) | Adobe-compliant PPD library covering SP 100, 110, 150, 200, 210, 230, 310 series |
| [`packaging/`](packaging/) | Packaging automation scripts (`.deb`, `.pkg`, `.tar.gz`) |
| [`setup.sh`](setup.sh) | Automated multi-model installer script |
| [`test_print.sh`](test_print.sh) | Single-page diagnostic test print script |
| [`uninstall.sh`](uninstall.sh) | Clean uninstallation script |
| [`Makefile`](Makefile) | Multi-platform build, packaging, and install system |
| [`.github/workflows/ci.yml`](.github/workflows/ci.yml) | Multi-OS GitHub Actions CI pipeline |
| [`.github/workflows/release.yml`](.github/workflows/release.yml) | Automated multi-format package release pipeline |
| [`AUTHORS.md`](AUTHORS.md) | Authors, upstream creators, and technical credits |
| [`LICENSE`](LICENSE) | MIT License |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Contribution & reverse engineering guidelines |
| [`SECURITY.md`](SECURITY.md) | Security vulnerability disclosure policy |

---

## Building & Publishing Packages

### Local Package Generation
You can build packages locally using the Makefile:
```bash
# Build the native package for your OS (.pkg on macOS, .deb on Linux) + tarballs
make package

# Or build individual package formats
make package-deb     # Debian / Ubuntu package
make package-pkg     # macOS installer package
make package-tar     # Binary and source distribution archives
```
All generated packages and checksums will be saved to the `dist/` directory.

### Automated Publishing via GitHub Actions
Creating and pushing a git release tag automatically triggers the Release CI workflow:
```bash
git tag v0.2.0
git push origin v0.2.0
```
The workflow will compile binaries for Ubuntu and macOS, generate Debian packages (`.deb`), macOS installer packages (`.pkg`), standalone archives (`.tar.gz`), compute SHA-256 checksums, and publish them to GitHub Releases.

---

## Credits & Acknowledgements

This project is built upon the collaborative work and reverse-engineering contributions of the open-source community:

- **[Aryan Kushwaha (@funinkina)](https://github.com/funinkina)**: Author of the original Ricoh SP 200 Linux/macOS driver project, initial reverse engineering of USB packet streams (`ricoh_capture.pcap`), and original C filter implementation.
- **[Alexey (@madlynx)](https://github.com/madlynx)**: Creator of the `ricoh-sp100` project, pioneering open-source DDST protocol research and PJL framing analysis.
- **[Markus Kuhn](https://www.cl.cam.ac.uk/~mgk25/jbigkit/)**: Author of `jbigkit` (`libjbig`), the open-source ITU-T T.82 JBIG1 bi-level image compression library used to encode the raster streams.
- **The CUPS & OpenPrinting Teams**: For developing and maintaining the open-source printing standards for macOS and Linux.

---

## Contributing

We welcome reports on new printer models, packet captures, and pull requests. Please see [CONTRIBUTING.md](CONTRIBUTING.md) for full details.

---

## License

This project is licensed under the [MIT License](LICENSE).
