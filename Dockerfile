# ==============================================================================
# Ricoh Universal DDST/GDI CUPS Network Print Server Container
# Registry: ghcr.io/ankitsingh99/ricoh-universal-ddst-driver
# ==============================================================================

# Stage 1: Build Filters
FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    make \
    libc6-dev \
    libcups2-dev \
    libcupsimage2-dev \
    libjbig-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .
RUN make clean && make CFLAGS="-O2 -Wall -Wextra" build

# Stage 2: Runtime CUPS Print Server
FROM debian:bookworm-slim

LABEL org.opencontainers.image.title="Ricoh Universal DDST Driver CUPS Server" \
      org.opencontainers.image.description="Network CUPS Print Server with pre-installed Ricoh DDST/GDI driver suite" \
      org.opencontainers.image.url="https://github.com/ankitsingh99/ricoh-universal-ddst-driver" \
      org.opencontainers.image.source="https://github.com/ankitsingh99/ricoh-universal-ddst-driver" \
      org.opencontainers.image.licenses="MIT"

RUN apt-get update && apt-get install -y --no-install-recommends \
    cups \
    cups-client \
    cups-filters \
    ghostscript \
    libjbig0 \
    jbigkit-bin \
    usbutils \
    && rm -rf /var/lib/apt/lists/*

# Install DDST Filter Binaries
COPY --from=builder /src/rastertoricohddst /usr/lib/cups/filter/rastertoricohddst
COPY --from=builder /src/rastertoricohjbig /usr/lib/cups/filter/rastertoricohjbig
RUN chmod 755 /usr/lib/cups/filter/rastertoricohddst /usr/lib/cups/filter/rastertoricohjbig

# Install PPD Profiles
COPY ppd/*.ppd /usr/share/ppd/cupsfilters/
COPY ricoh-sp200.ppd /usr/share/ppd/cupsfilters/
RUN chmod 644 /usr/share/ppd/cupsfilters/ricoh-sp*.ppd

# Configure CUPS for network access
RUN sed -i 's/Listen localhost:631/Port 631/' /etc/cups/cupsd.conf && \
    sed -i 's/<Location \/>/<Location \/>\n  Allow All/' /etc/cups/cupsd.conf && \
    sed -i 's/<Location \/admin>/<Location \/admin>\n  Allow All/' /etc/cups/cupsd.conf && \
    sed -i 's/<Location \/admin\/conf>/<Location \/admin\/conf>\n  Allow All/' /etc/cups/cupsd.conf && \
    echo "ServerAlias *" >> /etc/cups/cupsd.conf

# Create default admin user (cupsadmin / cupsadmin)
RUN useradd -r -G lpadmin -M cupsadmin && \
    echo "cupsadmin:cupsadmin" | chpasswd

EXPOSE 631

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD lpstat -r || exit 1

CMD ["/usr/sbin/cupsd", "-f"]
