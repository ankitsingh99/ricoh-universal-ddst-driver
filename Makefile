CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra
FILTER   = rastertoricohddst
LEGACY_FILTER = rastertoricohjbig
SRC      = rastertoricohddst.c
PPD_DIR_SRC = ppd
PRINTER ?= Ricoh_SP_200_DDST

UNAME := $(shell uname -s)

ifeq ($(UNAME), Darwin)
    # macOS CUPS environment
    BREW_PREFIX ?= $(shell brew --prefix 2>/dev/null || echo /opt/homebrew)
    FILTER_DIR   = /Library/Printers/Ricoh/Filter
    PPD_DIR      = /Library/Printers/PPDs/Contents/Resources
    CPPFLAGS    += -I$(BREW_PREFIX)/include
    LDFLAGS     += -L$(BREW_PREFIX)/lib
    LIBS         = -lcups -lcupsimage -ljbig
else
    # Linux CUPS environment
    FILTER_DIR   = /usr/lib/cups/filter
    PPD_DIR      = /usr/share/ppd/cupsfilters
    CUPS_CFLAGS := $(shell cups-config --cflags 2>/dev/null)
    CUPS_LIBS   := $(shell cups-config --libs 2>/dev/null || echo -lcups)
    CPPFLAGS    += $(CUPS_CFLAGS)
    LIBS         = $(CUPS_LIBS) -lcupsimage -ljbig
endif

VERSION ?= $(shell git describe --tags --always 2>/dev/null | sed 's/^v//' || echo 0.1.0)
DIST_DIR ?= dist

.PHONY: all build install uninstall register test clean help package package-deb package-pkg package-tar dist

all: build

help:
	@echo "Ricoh Universal DDST/GDI Driver Suite Makefile"
	@echo "-----------------------------------------------"
	@echo "make build         - Compile the CUPS raster filter binary"
	@echo "sudo make install  - Install filter and all PPDs into system directories"
	@echo "sudo make register - Register and enable default printer queue with CUPS"
	@echo "make test          - Send a test page to $(PRINTER)"
	@echo "sudo make uninstall- Remove printer queue and driver files"
	@echo "make package       - Build OS-specific install package & distribution archives"
	@echo "make package-deb   - Build Debian/Ubuntu .deb package"
	@echo "make package-pkg   - Build macOS .pkg installer package"
	@echo "make package-tar   - Build source and binary tarballs"
	@echo "make clean         - Remove compiled binaries and dist files"

build: $(FILTER) $(LEGACY_FILTER)

$(FILTER): $(SRC)
	$(CC) $(CFLAGS) $(CPPFLAGS) $(LDFLAGS) -o $@ $< $(LIBS)

$(LEGACY_FILTER): rastertoricohjbig.c
	$(CC) $(CFLAGS) $(CPPFLAGS) $(LDFLAGS) -o $@ $< $(LIBS)

install: build
	mkdir -p $(DESTDIR)$(FILTER_DIR) $(DESTDIR)$(PPD_DIR)
	install -m 755 $(FILTER) $(DESTDIR)$(FILTER_DIR)/$(FILTER)
	install -m 755 $(LEGACY_FILTER) $(DESTDIR)$(FILTER_DIR)/$(LEGACY_FILTER)
ifeq ($(UNAME), Darwin)
	# macOS sandbox requires absolute filter paths in PPDs and root:wheel ownership
	@for ppd in $(PPD_DIR_SRC)/*.ppd ricoh-sp200.ppd; do \
		if [ -f "$$ppd" ]; then \
			target="$(DESTDIR)$(PPD_DIR)/$$(basename $$ppd)"; \
			sed 's|application/vnd.cups-raster 0 rastertoricohddst|application/vnd.cups-raster 0 /Library/Printers/Ricoh/Filter/rastertoricohddst|g; s|application/vnd.cups-raster 0 rastertoricohjbig|application/vnd.cups-raster 0 /Library/Printers/Ricoh/Filter/rastertoricohjbig|g' "$$ppd" > "$$target"; \
			chmod 644 "$$target"; \
		fi; \
	done
	chown -R root:wheel /Library/Printers/Ricoh $(DESTDIR)$(PPD_DIR)/ricoh-sp*.ppd 2>/dev/null || true
	xattr -d com.apple.quarantine $(DESTDIR)$(FILTER_DIR)/$(FILTER) $(DESTDIR)$(FILTER_DIR)/$(LEGACY_FILTER) 2>/dev/null || true
else
	install -m 644 $(PPD_DIR_SRC)/*.ppd $(DESTDIR)$(PPD_DIR)/
	install -m 644 ricoh-sp200.ppd $(DESTDIR)$(PPD_DIR)/
endif
	@echo "Filter and PPD library installed successfully."
	@echo "Run 'sudo make register' or './setup.sh' to register your printer."

register:
	@URI=$$(/usr/libexec/cups/backend/usb 2>/dev/null | grep -i ricoh | awk '{print $$2}' | head -1); \
	if [ -z "$$URI" ]; then \
		URI=$$(lpinfo -v 2>/dev/null | grep -i ricoh | awk '{print $$2}' | head -1); \
	fi; \
	if [ -z "$$URI" ]; then \
		URI=$$(lpinfo -v 2>/dev/null | grep -i usb | awk '{print $$2}' | head -1); \
	fi; \
	if [ -z "$$URI" ]; then \
		echo "Note: Specific USB ID not discovered yet; registering with default 'usb://RICOH/SP%20200%20DDST'..."; \
		URI="usb://RICOH/SP%20200%20DDST"; \
	fi; \
	lpadmin -x $(PRINTER) 2>/dev/null || true; \
	lpadmin -p $(PRINTER) -v "$$URI" -P $(PPD_DIR)/ricoh-sp200.ppd -E && \
	cupsenable $(PRINTER) 2>/dev/null || true; \
	cupsaccept $(PRINTER) 2>/dev/null || true; \
	echo "Printer '$(PRINTER)' registered and enabled at $$URI."

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

uninstall:
	lpadmin -x $(PRINTER) 2>/dev/null || true
	rm -f $(DESTDIR)$(FILTER_DIR)/$(FILTER) $(DESTDIR)$(FILTER_DIR)/$(LEGACY_FILTER)
	rm -f $(DESTDIR)$(PPD_DIR)/ricoh-sp*.ppd
ifeq ($(UNAME), Darwin)
	rm -rf /Library/Printers/Ricoh 2>/dev/null || true
endif
	@echo "Uninstalled."

package-tar:
	@chmod +x packaging/build_tarball.sh
	./packaging/build_tarball.sh "$(VERSION)" "$(DIST_DIR)"

package-deb:
	@chmod +x packaging/build_deb.sh
	./packaging/build_deb.sh "$(VERSION)" "$(DIST_DIR)"

package-pkg:
	@chmod +x packaging/build_pkg.sh
	./packaging/build_pkg.sh "$(VERSION)" "$(DIST_DIR)"

ifeq ($(UNAME), Darwin)
package: package-pkg package-tar
else
package: package-deb package-tar
endif

dist: package

docker-build:
	docker build -t ghcr.io/ankitsingh99/ricoh-universal-ddst-driver:$(VERSION) -t ghcr.io/ankitsingh99/ricoh-universal-ddst-driver:latest .

clean:
	rm -f $(FILTER) $(LEGACY_FILTER)
	rm -rf $(DIST_DIR) build
