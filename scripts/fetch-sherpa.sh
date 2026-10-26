#!/bin/sh
# fetch-sherpa.sh — idempotent sherpa-onnx build for the stt project.
#
# Linux/Alpine (the device): sherpa-onnx has no Alpine package and its
# prebuilt tarballs are glibc (musl is our platform), so Stage 5 builds it
# from source against the system libonnxruntime (decision D14, PLAN §Stage 5).
# macOS (local development): k2-fsa's pinned osx-arm64 static-lib release is
# unpacked instead (it bundles libonnxruntime.a); nothing is compiled.
# The source tree and build live under var/tmp/sherpa-onnx/ (never versioned),
# where adapters/*/Makefile pick the static libs from.
#
# Idempotent: if the built C API library already exists, nothing runs
# (a second run works --offline and does not touch the network).
#
# Usage:
#   scripts/fetch-sherpa.sh [--offline] [--jobs N]
#
# Requires: Linux — git, cmake, g++, system libonnxruntime-dev; macOS arm64 — curl, tar.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TAG=v1.13.8
REPO=https://github.com/k2-fsa/sherpa-onnx.git
DIR=$ROOT/var/tmp/sherpa-onnx
OFFLINE=0
JOBS=2

usage() {
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case $1 in
        --offline) OFFLINE=1; shift ;;
        --jobs)    JOBS=${2:?--jobs needs a value}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *)         echo "fetch-sherpa: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

OS=$(uname -s)

if [ "$OS" != "Darwin" ] && { [ ! -f /usr/include/onnxruntime/onnxruntime_cxx_api.h ] || [ ! -e /usr/lib/libonnxruntime.so ]; }; then
    echo "fetch-sherpa: system libonnxruntime not found (need onnxruntime-dev)" >&2
    exit 1
fi

if [ -f "$DIR/build/lib/libsherpa-onnx-c-api.a" ]; then
    echo "cached: $DIR/build/lib/libsherpa-onnx-c-api.a"
    exit 0
fi

if [ "$OFFLINE" = 1 ]; then
    echo "fetch-sherpa: sherpa-onnx not built and --offline was requested" >&2
    exit 1
fi

if [ "$OS" = "Darwin" ]; then
    # Prebuilt static bundle for macOS arm64 (libs + libonnxruntime.a). The
    # only header the adapters need is the public C API, which is
    # self-contained (it includes nothing but <stdint.h>), so it is fetched
    # from the tagged source tree instead of cloning the whole repo.
    # Both artifacts are sha256-pinned.
    ARCH=$(uname -m)
    if [ "$ARCH" != "arm64" ]; then
        echo "fetch-sherpa: macOS prebuilts pinned for arm64 (got $ARCH)" >&2
        exit 1
    fi
    TARBALL="sherpa-onnx-$TAG-osx-arm64-static-lib.tar.bz2"
    TARBALL_SHA=9091bf160dc7fdacedbc906b212badf53c2993f4e5277a0e03998e96c31d60da
    HEADER_SHA=2a1b95084be8fd1deb3228fcad2fd3f7f0258b64582f7402281ec174c7b7f4ce
    sha_of() { sha256sum "$1" | cut -d' ' -f1; }

    mkdir -p "$DIR" "$DIR/sherpa-onnx/c-api"
    echo "download: $TARBALL"
    curl -fL --retry 3 --connect-timeout 15 -o "$DIR/$TARBALL.part" \
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/$TAG/$TARBALL"
    got=$(sha_of "$DIR/$TARBALL.part")
    if [ "$got" != "$TARBALL_SHA" ]; then
        rm -f "$DIR/$TARBALL.part"
        echo "fetch-sherpa: checksum mismatch for $TARBALL: got $got, want $TARBALL_SHA" >&2
        exit 1
    fi

    echo "download: sherpa-onnx/c-api/c-api.h"
    curl -fL --retry 3 --connect-timeout 15 -o "$DIR/sherpa-onnx/c-api/c-api.h.part" \
        "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/$TAG/sherpa-onnx/c-api/c-api.h"
    got=$(sha_of "$DIR/sherpa-onnx/c-api/c-api.h.part")
    if [ "$got" != "$HEADER_SHA" ]; then
        rm -f "$DIR/sherpa-onnx/c-api/c-api.h.part"
        echo "fetch-sherpa: checksum mismatch for c-api.h: got $got, want $HEADER_SHA" >&2
        exit 1
    fi

    tar xjf "$DIR/$TARBALL.part" -C "$DIR"
    rm -f "$DIR/$TARBALL.part"
    mkdir -p "$DIR/build"
    rm -rf "$DIR/build/lib"
    mv "$DIR/sherpa-onnx-$TAG-osx-arm64-static-lib/lib" "$DIR/build/lib"
    rmdir "$DIR/sherpa-onnx-$TAG-osx-arm64-static-lib"
    mv "$DIR/sherpa-onnx/c-api/c-api.h.part" "$DIR/sherpa-onnx/c-api/c-api.h"
    test -f "$DIR/build/lib/libsherpa-onnx-c-api.a"
    echo "ok: sherpa-onnx $TAG prebuilt static libs installed (osx-arm64)"
    exit 0
fi

if [ ! -d "$DIR" ]; then
    git clone --depth 1 --branch "$TAG" "$REPO" "$DIR"
fi

# GCC 15 (musl) stops inheriting <cstdint> transitively; upstream headers
# rely on it. -include cstdint fixes every translation unit at once.
# Minimal build: static C API only, no websocket/TTS/portaudio/tests/binaries.
cmake -S "$DIR" -B "$DIR/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_CXX_FLAGS="-include cstdint" \
    -DSHERPA_ONNX_ENABLE_PYTHON=OFF \
    -DSHERPA_ONNX_ENABLE_TESTS=OFF \
    -DSHERPA_ONNX_ENABLE_CHECK=OFF \
    -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
    -DSHERPA_ONNX_ENABLE_JNI=OFF \
    -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF \
    -DSHERPA_ONNX_ENABLE_TTS=OFF \
    -DSHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=OFF \
    -DSHERPA_ONNX_ENABLE_BINARY=OFF \
    -DSHERPA_ONNX_BUILD_C_API_EXAMPLES=OFF

# Memory-bound host: keep parallelism low (each g++ can take ~0.5 GB).
make -C "$DIR/build" -j"$JOBS"

test -f "$DIR/build/lib/libsherpa-onnx-c-api.a"
echo "ok: sherpa-onnx $TAG built (static C API + core against system onnxruntime)"
