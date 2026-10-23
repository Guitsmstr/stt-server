#!/bin/sh
# fetch-sherpa.sh — idempotent sherpa-onnx source build for the stt project.
#
# sherpa-onnx has no Alpine package and its prebuilt tarballs are glibc
# (musl is our platform), so Stage 5 builds it from source against the
# system libonnxruntime (decision D14, PLAN §Stage 5). The source tree and
# build live under var/tmp/sherpa-onnx/ (never versioned), where
# adapters/sherpa/Makefile picks the static libs from.
#
# Idempotent: if the built C API library already exists, nothing runs
# (a second run works --offline and does not touch the network).
#
# Usage:
#   scripts/fetch-sherpa.sh [--offline] [--jobs N]
#
# Requires: git, cmake, g++, system libonnxruntime-dev.
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

if [ ! -f /usr/include/onnxruntime/onnxruntime_cxx_api.h ] || [ ! -e /usr/lib/libonnxruntime.so ]; then
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
