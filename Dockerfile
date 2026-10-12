FROM golang:1.22-bookworm@sha256:1f298b0c9fecdf504389a0329236f948cc04a566a2bb32337207cbaaa2f8177c AS builder
WORKDIR /build
# Copy every Go source file, not just main.go: the sandbox hardening lives in
# harden.go (portable) plus harden_unix.go / harden_other.go (per-platform).
COPY go.mod ./
COPY main.go harden.go harden_unix.go harden_other.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /out/service .

# Modern and niche languages: Objective-C, Forth, Verilog, VHDL, Zig, Crystal
# and Dart. Objective-C needs clang (the gcc image has no Objective-C frontend
# enabled), Forth and Verilog need their own simulators, and three toolchains
# ship as self-contained release archives. Versions are pinned so an image
# rebuild cannot silently change the compiler a cached artifact was produced by.
#
# Swift is deliberately NOT in this image. Its toolchain is ~700MB unpacked and
# pulls Debian's ICU/xml2/z3 development libraries with it, which pushes this
# image past what a free-tier Render instance will build or hold. Swift is a
# planned entry for this service: point the backend at a Swift-specific service
# with COMPILER_SWIFT_SERVICE_URL when one exists, rather than making the other
# seven languages wait on a 4GB download.
FROM gcc:13.2-bookworm
LABEL org.opencontainers.image.title="codhoot-modern-service"
LABEL org.opencontainers.image.description="Hardened modern execution sandbox (forth, zig, crystal, dart, objectivec, verilog, vhdl)"

# APT toolchains. gobjc/libobjc provide the runtime clang links against for
# Objective-C.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends clang gobjc libobjc-12-dev gforth iverilog ghdl; \
    rm -f /usr/bin/curl /usr/bin/wget /usr/local/bin/curl /usr/local/bin/wget; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# --- Single-binary toolchains -------------------------------------------------
# Each archive contains the compiler and its standard library with no build step.
ARG ZIG_VERSION=0.13.0
ARG CRYSTAL_VERSION=1.10.1

RUN set -eux; \
    apt-get update; \
    # --reinstall, not a plain install: the base image deletes the curl binary
    # for security while leaving dpkg's record intact, so `apt-get install curl`
    # reports "already the newest version" and leaves the binary missing.
    apt-get install -y --no-install-recommends --reinstall curl; \
    apt-get install -y --no-install-recommends xz-utils ca-certificates; \
    mkdir -p /opt/toolchains/zig /opt/toolchains/crystal; \
    curl -fsSL -o /tmp/zig.tar.xz \
      "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz"; \
    tar -xJf /tmp/zig.tar.xz -C /opt/toolchains/zig --strip-components=1; \
    curl -fsSL -o /tmp/crystal.tar.gz \
      "https://github.com/crystal-lang/crystal/releases/download/${CRYSTAL_VERSION}/crystal-${CRYSTAL_VERSION}-1-linux-x86_64.tar.gz"; \
    tar -xzf /tmp/crystal.tar.gz -C /opt/toolchains/crystal --strip-components=1; \
    rm -f /tmp/zig.tar.xz /tmp/crystal.tar.gz; \
    apt-get purge -y --auto-remove curl; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    ln -sf /opt/toolchains/zig/zig /usr/local/bin/zig; \
    ln -sf /opt/toolchains/crystal/bin/crystal /usr/local/bin/crystal; \
    chmod -R +x /opt/toolchains/zig/zig /opt/toolchains/crystal/bin

# Dart is a zip, so unzip is fetched alongside curl and both are purged when the
# download is done.
ARG DART_VERSION=3.13.5

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends --reinstall curl unzip ca-certificates; \
    mkdir -p /opt/toolchains/dart; \
    curl -fsSL -o /tmp/dart.zip \
      "https://storage.googleapis.com/dart-archive/channels/stable/release/${DART_VERSION}/sdk/dartsdk-linux-x64-release.zip"; \
    unzip -q /tmp/dart.zip -d /opt/toolchains/dart; \
    rm -f /tmp/dart.zip; \
    ln -sf /opt/toolchains/dart/dart-sdk/bin/dart /usr/local/bin/dart; \
    # unzip does not preserve the executable bit, so dart arrives non-executable.
    chmod -R +x /opt/toolchains/dart/dart-sdk/bin; \
    apt-get purge -y --auto-remove unzip; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# Every binary the service dispatches to must be present, and this is the same
# assertion one layer earlier: the wrapper refuses to open its port unless each
# tool it can hand a program to is on PATH, so a missing toolchain fails the
# deploy rather than the first student's submission.
#
# What a toolchain does when it runs is deliberately not exercised here. A
# compile-and-run one-liner in the build makes a typo in that one-liner fail
# the deploy for every language on the image, which is a worse trade than
# finding out on first use.
RUN set -eux; \
    for bin in gforth zig crystal dart clang iverilog vvp ghdl; do \
      command -v "$bin" > /dev/null; \
    done

WORKDIR /app
COPY --from=builder /out/service /app/service
RUN chmod 0755 /app/service && rm -f go.mod main.go harden.go harden_unix.go harden_other.go

# --- sandbox identity pool ---------------------------------------------------
# Each in-flight job is dropped to a DISTINCT uid by the service. That is what
# makes a job's 0700 working directory genuinely private: with one shared uid every
# job could read every other job's source and rewrite it before it ran.
# Runtimes that resolve getpwuid need real passwd entries, written directly here
# rather than with 32 useradd calls.
# shellcheck disable=SC2016
RUN set -eu; \
    i=0; \
    while [ "$i" -lt 32 ]; do \
      u=$((2000 + i)); \
      printf 'codhoot-s%d:x:%d:%d:codhoot sandbox:/nonexistent:/sbin/nologin\n' "$i" "$u" "$u" >> /tmp/pool; \
      i=$((i + 1)); \
    done; \
    cat /tmp/pool >> /etc/passwd; \
    rm -f /tmp/pool; \
    mkdir -p /tmp/codhoot-cache; \
    chmod 0755 /tmp/codhoot-cache

# The service itself runs as root on purpose: it must chown each job directory to
# that job's uid and setuid the compiler/runtime child. The security boundary is
# the child, not the service.
#
# There is deliberately no HEALTHCHECK here: it would require curl or wget in the
# image, and Render already health-checks /health over HTTP.
ENV PORT=8081
EXPOSE 8081
CMD ["/app/service"]