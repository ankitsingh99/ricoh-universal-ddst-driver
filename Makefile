# ==============================================================================
# Ricoh Universal DDST/GDI Driver Suite - Universal Makefile
# Supports: Linux, FreeBSD, OpenBSD, NetBSD, macOS (Darwin), Solaris/illumos, AIX
# Compatible with both GNU make (gmake) and BSD make (bmake / fmake)
# ==============================================================================

CC            ?= gcc
CFLAGS        ?= -O2 -Wall -Wextra
FILTER         = rastertoricohddst
LEGACY_FILTER  = rastertoricohjbig
SRC            = rastertoricohddst.c
PPD_DIR_SRC    = ppd
PRINTER       ?= Ricoh_SP_200_DDST
VERSION       ?= 0.1.0
DIST_DIR      ?= dist

# Universal include and library paths for Linux, BSDs, and macOS (Intel & Apple Silicon)
CPPFLAGS      += -I/usr/local/include -I/usr/pkg/include -I/opt/homebrew/include
LDFLAGS       += -L/usr/local/lib -L/usr/pkg/lib -L/opt/homebrew/lib
LIBS          ?= -lcups -lcupsimage -ljbig

.PHONY: all build install uninstall register test test-coverage test-network test-os enable-sharing disable-sharing status-sharing clean help package package-deb package-pkg package-tar dist

all: build

help:
	@echo "Ricoh Universal DDST/GDI Driver Suite Makefile"
	@echo "--------------------------------------------------------"
	@echo "make build           - Compile the CUPS raster filter binaries"
	@echo "sudo make install    - Install filters and PPDs to system CUPS directories"
	@echo "sudo make register   - Register and enable default printer queue with CUPS"
	@echo "make enable-sharing  - Enable AirPrint & IPP network printing for mobile devices"
	@echo "make status-sharing  - Check network sharing, queue, and mDNS status"
	@echo "make disable-sharing - Disable network sharing and stop mDNS advertisement"
	@echo "make test            - Send a test page to $(PRINTER)"
	@echo "make test-coverage   - Run comprehensive unit & integration test suite with gcov"
	@echo "make test-network    - Run mobile & network printing integration tests"
	@echo "make test-os         - Run full cross-platform Multi-OS compatibility test suite"
	@echo "sudo make uninstall  - Remove printer queue and driver files"
	@echo "make package         - Build OS-specific install package & distribution archives"
	@echo "make package-deb     - Build Debian/Ubuntu .deb package"
	@echo "make package-pkg     - Build macOS .pkg installer package"
	@echo "make package-tar     - Build portable release tarballs (.tar.gz)"
	@echo "make clean           - Remove compiled binaries and dist files"

build: $(FILTER) $(LEGACY_FILTER)

$(FILTER): $(SRC)
	$(CC) $(CFLAGS) $(CPPFLAGS) $$(cups-config --cflags 2>/dev/null) $(LDFLAGS) -o $@ $< $(LIBS) $$(cups-config --libs 2>/dev/null)

$(LEGACY_FILTER): rastertoricohjbig.c
	$(CC) $(CFLAGS) $(CPPFLAGS) $$(cups-config --cflags 2>/dev/null) $(LDFLAGS) -o $@ $< $(LIBS) $$(cups-config --libs 2>/dev/null)

install: build
	@OS="$$(uname -s)"; \
	FDIR="$(FILTER_DIR)"; \
	PDIR="$(PPD_DIR)"; \
	if [ -z "$$FDIR" ]; then \
		if [ "$$OS" = "Darwin" ]; then \
			FDIR="/Library/Printers/Ricoh/Filter"; \
		elif command -v cups-config >/dev/null 2>&1; then \
			FDIR="$$(cups-config --serverbin 2>/dev/null)/filter"; \
		elif [ -d "/usr/local/libexec/cups/filter" ]; then \
			FDIR="/usr/local/libexec/cups/filter"; \
		elif [ -d "/usr/pkg/libexec/cups/filter" ]; then \
			FDIR="/usr/pkg/libexec/cups/filter"; \
		else \
			FDIR="/usr/lib/cups/filter"; \
		fi; \
	fi; \
	if [ -z "$$PDIR" ]; then \
		if [ "$$OS" = "Darwin" ]; then \
			PDIR="/Library/Printers/PPDs/Contents/Resources"; \
		elif [ -d "/usr/share/ppd/cupsfilters" ]; then \
			PDIR="/usr/share/ppd/cupsfilters"; \
		elif command -v cups-config >/dev/null 2>&1; then \
			PDIR="$$(cups-config --datadir 2>/dev/null)/model"; \
		elif [ -d "/usr/local/share/cups/model" ]; then \
			PDIR="/usr/local/share/cups/model"; \
		elif [ -d "/usr/pkg/share/cups/model" ]; then \
			PDIR="/usr/pkg/share/cups/model"; \
		else \
			PDIR="/usr/share/cups/model"; \
		fi; \
	fi; \
	echo "Installing to Filter Dir: $(DESTDIR)$$FDIR"; \
	echo "Installing to PPD Dir:    $(DESTDIR)$$PDIR"; \
	mkdir -p "$(DESTDIR)$$FDIR" "$(DESTDIR)$$PDIR"; \
	install -m 755 $(FILTER) "$(DESTDIR)$$FDIR/$(FILTER)"; \
	install -m 755 $(LEGACY_FILTER) "$(DESTDIR)$$FDIR/$(LEGACY_FILTER)"; \
	if [ "$$OS" = "Darwin" ]; then \
		for ppd in $(PPD_DIR_SRC)/*.ppd ricoh-sp200.ppd; do \
			if [ -f "$$ppd" ]; then \
				target="$(DESTDIR)$$PDIR/$$(basename "$$ppd")"; \
				sed "s|application/vnd.cups-raster 0 rastertoricohddst|application/vnd.cups-raster 0 $$FDIR/rastertoricohddst|g; s|application/vnd.cups-raster 0 rastertoricohjbig|application/vnd.cups-raster 0 $$FDIR/rastertoricohjbig|g" "$$ppd" > "$$target"; \
				chmod 644 "$$target"; \
			fi; \
		done; \
		chown -R root:wheel /Library/Printers/Ricoh "$(DESTDIR)$$PDIR"/ricoh-sp*.ppd 2>/dev/null || true; \
		xattr -d com.apple.quarantine "$(DESTDIR)$$FDIR/$(FILTER)" "$(DESTDIR)$$FDIR/$(LEGACY_FILTER)" 2>/dev/null || true; \
	else \
		for ppd in $(PPD_DIR_SRC)/*.ppd ricoh-sp200.ppd; do \
			if [ -f "$$ppd" ]; then \
				install -m 644 "$$ppd" "$(DESTDIR)$$PDIR/"; \
			fi; \
		done; \
	fi; \
	echo "Filter and PPD library installed successfully."

register:
	@URI=""; \
	if command -v cups-config >/dev/null 2>&1; then \
		BACKEND_DIR="$$(cups-config --serverbin 2>/dev/null)/backend"; \
		if [ -x "$$BACKEND_DIR/usb" ]; then \
			URI=$$("$$BACKEND_DIR/usb" 2>/dev/null | grep -i ricoh | awk '{print $$2}' | head -1 || true); \
		fi; \
	fi; \
	if [ -z "$$URI" ] && [ -x "/usr/libexec/cups/backend/usb" ]; then \
		URI=$$(/usr/libexec/cups/backend/usb 2>/dev/null | grep -i ricoh | awk '{print $$2}' | head -1 || true); \
	fi; \
	if [ -z "$$URI" ] && [ -x "/usr/local/libexec/cups/backend/usb" ]; then \
		URI=$$(/usr/local/libexec/cups/backend/usb 2>/dev/null | grep -i ricoh | awk '{print $$2}' | head -1 || true); \
	fi; \
	if [ -z "$$URI" ] && [ -x "/usr/lib/cups/backend/usb" ]; then \
		URI=$$(/usr/lib/cups/backend/usb 2>/dev/null | grep -i ricoh | awk '{print $$2}' | head -1 || true); \
	fi; \
	if [ -z "$$URI" ]; then \
		URI=$$(lpinfo -v 2>/dev/null | grep -i ricoh | awk '{print $$2}' | head -1 || true); \
	fi; \
	if [ -z "$$URI" ]; then \
		URI=$$(lpinfo -v 2>/dev/null | grep -i usb | awk '{print $$2}' | head -1 || true); \
	fi; \
	if [ -z "$$URI" ]; then \
		echo "Note: Specific USB ID not discovered yet; registering with default 'usb://RICOH/SP%20200%20DDST'..."; \
		URI="usb://RICOH/SP%20200%20DDST"; \
	fi; \
	PPD_PATH=""; \
	for candidate in /Library/Printers/PPDs/Contents/Resources/ricoh-sp200.ppd \
	                 /usr/share/ppd/cupsfilters/ricoh-sp200.ppd \
	                 /usr/local/share/cups/model/ricoh-sp200.ppd \
	                 /usr/pkg/share/cups/model/ricoh-sp200.ppd \
	                 ppd/ricoh-sp200.ppd ricoh-sp200.ppd; do \
		if [ -f "$$candidate" ]; then PPD_PATH="$$candidate"; break; fi; \
	done; \
	lpadmin -x $(PRINTER) 2>/dev/null || true; \
	lpadmin -p $(PRINTER) -v "$$URI" -P "$$PPD_PATH" -E && \
	lpadmin -p $(PRINTER) -o printer-is-shared=true -o printer-error-policy=retry-current-job 2>/dev/null || true; \
	cupsenable $(PRINTER) 2>/dev/null || true; \
	cupsaccept $(PRINTER) 2>/dev/null || true; \
	echo "Printer '$(PRINTER)' registered and enabled at $$URI using $$PPD_PATH."

test:
	@echo "Sending test print to $(PRINTER)..."
	@{ \
		printf "========================================\n"; \
		printf "  Ricoh Universal DDST Test Page\n"; \
		printf "  Date: %s\n" "$$(date)"; \
		printf "  Driver: Native Universal DDST Filter\n"; \
		printf "========================================\n"; \
	} | lpr -P $(PRINTER)
	@echo "Job submitted."

test-coverage:
	@chmod +x tests/run_coverage.sh
	./tests/run_coverage.sh

test-network:
	@chmod +x tests/test_network_printing.sh
	./tests/test_network_printing.sh

test-os:
	@chmod +x tests/test_os_compatibility.sh
	./tests/test_os_compatibility.sh

enable-sharing:
	@chmod +x enable_network_printing.sh
	./enable_network_printing.sh --enable --printer $(PRINTER)

disable-sharing:
	@chmod +x enable_network_printing.sh
	./enable_network_printing.sh --disable --printer $(PRINTER)

status-sharing:
	@chmod +x enable_network_printing.sh
	./enable_network_printing.sh --status --printer $(PRINTER)

uninstall:
	lpadmin -x $(PRINTER) 2>/dev/null || true
	@FDIR="$(FILTER_DIR)"; \
	PDIR="$(PPD_DIR)"; \
	for f in "$$FDIR/$(FILTER)" "$$FDIR/$(LEGACY_FILTER)" \
	         /Library/Printers/Ricoh/Filter/$(FILTER) /Library/Printers/Ricoh/Filter/$(LEGACY_FILTER) \
	         /usr/lib/cups/filter/$(FILTER) /usr/lib/cups/filter/$(LEGACY_FILTER) \
	         /usr/local/libexec/cups/filter/$(FILTER) /usr/local/libexec/cups/filter/$(LEGACY_FILTER) \
	         /usr/pkg/libexec/cups/filter/$(FILTER) /usr/pkg/libexec/cups/filter/$(LEGACY_FILTER); do \
		[ -n "$$f" ] && rm -f "$(DESTDIR)$$f" 2>/dev/null || true; \
	done; \
	for p in "$$PDIR" /Library/Printers/PPDs/Contents/Resources /usr/share/ppd/cupsfilters \
	         /usr/share/cups/model /usr/local/share/cups/model /usr/pkg/share/cups/model; do \
		[ -d "$$p" ] && rm -f "$(DESTDIR)$$p"/ricoh-sp*.ppd 2>/dev/null || true; \
	done; \
	if [ "$$(uname -s)" = "Darwin" ]; then \
		rm -rf /Library/Printers/Ricoh 2>/dev/null || true; \
	fi; \
	echo "Uninstalled."

package-tar:
	@chmod +x packaging/build_tarball.sh
	./packaging/build_tarball.sh "$(VERSION)" "$(DIST_DIR)"

package-deb:
	@chmod +x packaging/build_deb.sh
	./packaging/build_deb.sh "$(VERSION)" "$(DIST_DIR)"

package-pkg:
	@chmod +x packaging/build_pkg.sh
	./packaging/build_pkg.sh "$(VERSION)" "$(DIST_DIR)"

package:
	@OS="$$(uname -s)"; \
	if [ "$$OS" = "Darwin" ]; then \
		$(MAKE) package-pkg package-tar; \
	elif [ -f /etc/debian_version ]; then \
		$(MAKE) package-deb package-tar; \
	else \
		$(MAKE) package-tar; \
	fi

dist: package

docker-build:
	docker build -t ghcr.io/ankitsingh99/ricoh-universal-ddst-driver:$(VERSION) -t ghcr.io/ankitsingh99/ricoh-universal-ddst-driver:latest .

clean:
	rm -f $(FILTER) $(LEGACY_FILTER) *.gcda *.gcno *.gcov *.o
	rm -rf $(DIST_DIR) build
