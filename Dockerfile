FROM debian:trixie-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4 AS runtime

ARG DEBIAN_SNAPSHOT=20261103T000000Z

RUN sed -i \
        -e "s|http://deb.debian.org/debian-security|http://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT}/|" \
        -e "s|http://deb.debian.org/debian$|http://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}/|" \
        -e '/Signed-By:/a Check-Valid-Until: no' \
        /etc/apt/sources.list.d/debian.sources \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates=20250419+deb13u1 \
        curl=8.14.1-2+deb13u7 \
        git=1:2.47.3-0+deb13u1 \
        tini=0.19.0-3+b8 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 1000 --user-group --shell /bin/bash container

FROM runtime AS download

ARG TARGETARCH
ARG ZIG_VERSION=0.17.0

RUN apt-get update \
    && apt-get install -y --no-install-recommends minisign=0.12-1 xz-utils=5.8.1-1+deb13u2 \
    && case "$TARGETARCH" in \
        amd64) arch=x86_64 ;; \
        arm64) arch=aarch64 ;; \
        *) echo "Unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && archive="zig-${arch}-linux-${ZIG_VERSION}.tar.xz" \
    && curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 --retry 3 \
        "https://ziglang.org/download/${ZIG_VERSION}/${archive}" -o /tmp/zig.tar.xz \
    && curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 --retry 3 \
        "https://ziglang.org/download/${ZIG_VERSION}/${archive}.minisig" -o /tmp/zig.tar.xz.minisig \
    && minisign -Vm /tmp/zig.tar.xz -P RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U \
    && mkdir /opt/zig \
    && tar -xJf /tmp/zig.tar.xz --no-same-owner --strip-components=1 -C /opt/zig \
    && test "$(/opt/zig/zig version)" = "$ZIG_VERSION" \
    && rm -rf /opt/zig/doc

FROM runtime

ENV USER=container \
    HOME=/home/container \
    XDG_CACHE_HOME=/home/container/.cache \
    ZIG_GLOBAL_CACHE_DIR=/home/container/.cache/zig \
    PATH=/opt/zig:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

COPY --from=download /opt/zig /opt/zig
COPY --chmod=755 entrypoint.sh /entrypoint.sh

USER 1000:1000
WORKDIR /home/container
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/entrypoint.sh"]
CMD ["zig", "version"]
