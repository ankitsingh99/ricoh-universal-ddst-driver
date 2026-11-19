# Authors & Contributors

This project is built upon the collaborative work and reverse-engineering efforts of the open-source printing community.

---

## Original Authors & Upstream Contributors

- **Aryan Kushwaha ([@funinkina](https://github.com/funinkina))**
  - Author of the original Ricoh SP 200 Linux/macOS driver project.
  - Reverse-engineered the USB packet traffic (`ricoh_capture.pcap`) and authored the initial native C filter implementation and PPD structure.

---

## Maintainers & Universal Suite Contributors

- **Ankit Kumar Singh ([@ankitsingh99](https://github.com/ankitsingh99))**
  - Expanded the driver into the Universal Ricoh DDST/GDI Suite (`rastertoricohddst`).
  - Added multi-model PPD library (SP 100, 110, 150, 200, 210, 230, 310 series), native LHPL filter (`rastertoricohlhpl`), auto printer detection, hardware duplexing, and multi-tray support.
  - Built automated multi-platform installers, macOS sandbox root permissions setup, and cross-platform CI pipelines.

---

## Technical Acknowledgements & Prior Art

- **Alexey ([@madlynx](https://github.com/madlynx))**: For pioneering open-source DDST protocol analysis and documentation in the `ricoh-sp100` project.
- **Markus Kuhn**: For creating `jbigkit` (`libjbig`), the open-source ITU-T T.82 JBIG1 bi-level image compression library used to encode the raster streams.
- **The OpenPrinting & CUPS Project**: For maintaining the Linux and macOS standard printing stacks and documentation.
- **Artificial Intelligence (AI) Assistance**: Utilized in protocol analysis, codebase modernization, multi-model extrapolation, and documentation structuring.

---

## Hardware Testing Scope

- Physical verification was performed on the **Ricoh SP 200**.
- Compatibility for additional models is extrapolated from DDST/GDI wire protocol specifications. Community feedback, error reports, and hardware testing results are welcome in [GitHub Discussions](https://github.com/ankitsingh99/ricoh-universal-ddst-driver/discussions).

