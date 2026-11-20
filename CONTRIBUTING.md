# Contributing to Ricoh Universal DDST/GDI/LHPL Driver Suite

Thank you for your interest in improving the Ricoh Universal DDST/GDI/LHPL CUPS Driver Suite! Community contributions help keep this driver working across diverse Linux distributions, macOS versions, and the wide range of Ricoh DDST, GDI, and LHPL printer models.

---

> [!IMPORTANT]
> **Hardware Testing & Model Support Status**
> - **Tested Hardware**: The codebase and USB print streams are physically tested and verified on the **Ricoh SP 200** printer.
> - **Extrapolated Support**: Support for other models (such as SP 100, SP 110/111/112, SP 150, SP 210, SP 230, and SP 310 series) has been **extrapolated** from DDST and LHPL protocol specifications and reverse-engineered packet captures, but has **not yet been physically tested on those models** by the maintainer.
> - **Open a Discussion for Issues & Compatibility**: If you encounter errors, unexpected behavior, or want to report successful testing on other models, please [**Open a Discussion on GitHub**](https://github.com/ankitsingh99/ricoh-universal-ddst-driver/discussions).
> - **Contributions Welcome**: Community contributions (testing feedback, bug fixes, USB captures, and documentation) are warmly welcomed!

> [!NOTE]
> **AI Usage Notice**: This project utilized Artificial Intelligence (AI) assistance for protocol analysis, codebase modernization, and multi-model feature extrapolation.

---

## Code of Conduct

Please note that this project is released with a [Contributor Code of Conduct](CODE_OF_CONDUCT.md). By participating in this project you agree to abide by its terms.

---

## How Can I Contribute?

### 1. Reporting Bugs & Asking Questions
Before submitting an issue, please check existing issues and [Discussions](https://github.com/ankitsingh99/ricoh-universal-ddst-driver/discussions) to avoid duplicates. When opening a discussion or issue, provide:
- Your Operating System and architecture (`uname -a`).
- CUPS version (`cups-config --version` or `cupsd --version`).
- Printer model (e.g., Ricoh SP 100, SP 111, SP 150, SP 200, SP 210, SP 230, SP 310, etc.).
- Connection type (USB or Network).
- Relevant CUPS log output from `/var/log/cups/error_log` (or `cupsctl --debug-logging` enabled logs).

### 2. Testing Other Printer Models
If you own any Ricoh DDST or LHPL printer (such as Ricoh SP 100, SP 111, SP 150, SP 210, SP 212, SP 220, SP 230, SP 310, SP 325, SP 3710), test the driver and let us know your results in GitHub Discussions!
- If the printer works or needs tweaks, open a Discussion or PR to update the compatibility matrix.
- If you have USB packet captures from the Windows driver, see [Capturing USB Traffic](#capturing-usb-traffic) below.

### 3. Submitting Pull Requests
1. **Fork the repository** and clone your fork locally.
2. **Create a feature branch** from `main`:
   ```bash
   git checkout -b feature/my-feature-name
   ```
3. **Make your changes** following our coding standards.
4. **Test your changes**:
   - Verify PPD syntax:
     ```bash
     for f in ppd/*.ppd; do cupstestppd "$f"; done
     ```
   - Compile filter cleanly with warnings enabled:
     ```bash
     make clean && make build
     ```
   - Test shell scripts for syntax:
     ```bash
     bash -n setup.sh test_print.sh uninstall.sh
     ```
5. **Commit with descriptive commit messages** (e.g. Conventional Commits format `feat: ...`, `fix: ...`, `docs: ...`).
6. **Push to your fork** and submit a Pull Request.

---

## Development & Build Environment

### Prerequisites

- **C Compiler**: GCC or Clang (supporting C99).
- **Libraries**:
  - `libcups` and `libcupsimage`
  - `jbigkit` (`libjbig`)
- **Utilities**: `make`, `cups`, `ghostscript`.

### Building Locally

```bash
# Build filter binaries
make build

# Validate PPD syntax
for f in ppd/*.ppd; do cupstestppd "$f"; done

# Clean build artifacts
make clean
```

---

## Coding Standards

### C Source (`rastertoricohddst.c` / `rastertoricohjbig.c`)
- Adhere to **C99** standards.
- Follow CUPS filter conventions:
  - Read input from file descriptor passed in `argv[6]` if provided, or from stdin (`0`).
  - Output page status messages (`PAGE: page-number num-copies`) to `stderr`.
  - Output diagnostic messages (`DEBUG:`, `INFO:`, `ERROR:`) to `stderr`.
  - Write binary PJL / JBIG1 payload to `stdout`.
- Check all memory allocations and return codes safely.
- Avoid memory leaks.

### Shell Scripts (`*.sh`)
- Use portable POSIX/Bash syntax.
- Always quote variables properly (e.g. `"$VAR"`).
- Handle error conditions cleanly and provide informative output.

---

## Capturing USB Traffic (For Protocol Reverse Engineering)

If you are investigating unsupported features (e.g., duplexing, manual tray, resolution modes):
1. On a Windows machine running the official Ricoh driver, use **Wireshark** with **USBPcap** or **USBlyzer**.
2. Capture traffic while sending a 1-page document with known contents.
3. Save the `.pcap` capture and inspect PJL command headers and JBIG compression parameters (BIE header bytes).

