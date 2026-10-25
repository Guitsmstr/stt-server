#!/bin/sh
# fetch-laya — Laya decision models (judge) + ggmlc `laya` CLI for offline
# post-processing experiments (keyboard-style corrector, MODELOS §6.2).
#
# Why: Laya answers typed questions (choice/score/noul) with calibrated
# probabilities in one encoder pass and never generates text. For Spanish the
# multilingual checkpoint is the right judge: the English checkpoint collapses
# off English (measured 2026-10-25, Sesión 019: word-level ES decisions at
# chance level, conf 0.12-0.16). Measured on this device (Helio G80):
#   laya-multilingual Q8_0 (`laya serve`, CPU): RSS 516-571 MB, load ~1 s,
#   1.1-1.5 s per decision idle, 1.6-2.5 s under kroko-es STT load.
#   Coexists with kroko-es (254 MB): ~825 MB combined RSS, STT RTF 0.22 idle,
#   0.49-0.52 while judging (still real-time).
#
# WARNING (memory): do not keep whisper-small (758 MB) + Laya resident at the
# same time on this device (1.3+ GB model RSS against 1.7-2.2 GB free; the
# MediaTek kernel panicked under that class of pressure, MODELOS §5). Run the
# second engine sequentially.
#
# Builds:
#   ggmlc v0.9.7 (release tarball, sha256 pinned) -> var/tmp/ggmlc
#     -> var/tmp/ggmlc/build/examples/laya/laya   (CPU, musl; patch applied:
#        missing <sys/time.h> in examples/laya/src/server.cpp)
# Models (sha256 pinned = HF LFS oid, verified 2026-10-25):
#   mys/laya-multilingual-GGUF laya_multilingual_q8_0.gguf
#     -> var/models/laya-multilingual/  (345 MB; mmBERT 322M, ES/100+ idiomas)
#   ggml-org/Laya-GGUF Laya-Q8_0.gguf
#     -> var/models/laya/               (429 MB; ModernBERT, inglés)
#
# Usage:
#   scripts/fetch-laya.sh [--offline] [--skip-english]
#
# Idempotent: skips work already done; --offline fails instead of downloading.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GGMLC_VER=0.9.7
GGMLC_URL=https://github.com/monatis/ggmlc/releases/download/v$GGMLC_VER/ggmlc-$GGMLC_VER.tar.gz
GGMLC_SHA=2081c3fc6c8c339198339bb083f12ebae803ad89e3a3ece58c52af2b73a04020
GGMLC_DIR=$ROOT/var/tmp/ggmlc
LAYA_BIN=$GGMLC_DIR/build/examples/laya/laya

MULTI_DIR=$ROOT/var/models/laya-multilingual
MULTI_URL=https://huggingface.co/mys/laya-multilingual-GGUF/resolve/main
MULTI_GGUF=laya_multilingual_q8_0.gguf
MULTI_SHA=757c1a4b1f0f41824113dde76d6cd06b0881d37b796103a338de77f9f9b935c3

EN_DIR=$ROOT/var/models/laya
EN_URL=https://huggingface.co/ggml-org/Laya-GGUF/resolve/main
EN_GGUF=Laya-Q8_0.gguf
EN_SHA=c06528c5746d3bb8baa72a27938be95abbfd0b226f8471e8a9e365ed0bb066d2

OFFLINE=0
SKIP_ENGLISH=0

usage() { sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case $1 in
        --offline)      OFFLINE=1; shift ;;
        --skip-english) SKIP_ENGLISH=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "fetch-laya: unknown argument: $1" >&2; exit 2 ;;
    esac
done

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

need curl; need sha256sum; need tar; need cmake; need make; need g++

fetch() { # fetch <url> <dest> <sha>
    [ -f "$2" ] && [ "$(sha256sum "$2" | cut -d' ' -f1)" = "$3" ] && { say "cached: $2"; return 0; }
    [ "$OFFLINE" = 1 ] && die "missing $2 and --offline was requested"
    say "fetch: $1"
    curl -sSL -o "$2" "$1"
    [ "$(sha256sum "$2" | cut -d' ' -f1)" = "$3" ] || die "sha256 mismatch: $2"
}

# -- ggmlc source (pinned release tarball)
if [ -d "$GGMLC_DIR" ]; then
    say "cached: ggmlc $GGMLC_VER source"
else
    [ "$OFFLINE" = 1 ] && die "ggmlc $GGMLC_VER missing and --offline was requested"
    say "fetch: ggmlc $GGMLC_VER"
    tmp=$(mktemp)
    curl -sSL -o "$tmp" "$GGMLC_URL"
    [ "$(sha256sum "$tmp" | cut -d' ' -f1)" = "$GGMLC_SHA" ] || die "sha256 mismatch: ggmlc tarball"
    mkdir -p "$GGMLC_DIR"
    tar xzf "$tmp" -C "$GGMLC_DIR" --strip-components=1
    rm -f "$tmp"
fi

# -- musl patch (idempotent): server.cpp uses struct timeval without <sys/time.h>
if grep -q '#include <sys/time.h>' "$GGMLC_DIR/examples/laya/src/server.cpp" 2>/dev/null; then
    say "cached: musl patch"
else
    sed -i '/#include <sys\/socket.h>/a #include <sys/time.h>' \
        "$GGMLC_DIR/examples/laya/src/server.cpp"
    say "patched: examples/laya/src/server.cpp (+ <sys/time.h>)"
fi

# -- build (once; keep jobs low: RAM-constrained device)
if [ -x "$LAYA_BIN" ]; then
    say "cached: laya build"
else
    [ "$OFFLINE" = 1 ] && die "laya build missing and --offline was requested"
    say "build: laya (-j2)"
    cmake -S "$GGMLC_DIR" -B "$GGMLC_DIR/build" -DCMAKE_BUILD_TYPE=Release \
        -DGGMLC_BUILD_EXAMPLES=ON >/dev/null
    cmake --build "$GGMLC_DIR/build" --target laya -j2
fi

# -- models
mkdir -p "$MULTI_DIR"
fetch "$MULTI_URL/$MULTI_GGUF" "$MULTI_DIR/$MULTI_GGUF" "$MULTI_SHA"

if [ "$SKIP_ENGLISH" = 1 ]; then
    say "skipped: english checkpoint (--skip-english)"
else
    mkdir -p "$EN_DIR"
    fetch "$EN_URL/$EN_GGUF" "$EN_DIR/$EN_GGUF" "$EN_SHA"
fi

say "done. judge server (spanish):"
say "  $LAYA_BIN serve $MULTI_DIR/$MULTI_GGUF --port 8092 --device cpu"
say "probe:"
say "  python3 tests/laya_probe.py --url http://127.0.0.1:8092"
