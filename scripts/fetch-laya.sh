#!/bin/sh
# fetch-laya — Laya decision models (judge) + `laya` CLI for offline
# post-processing experiments (keyboard-style corrector, MODELOS §6.2).
#
# Why: Laya answers typed questions (choice/score/noul) with calibrated
# probabilities in one encoder pass and never generates text. For Spanish the
# multilingual checkpoint is the right judge: the English checkpoint collapses
# off English (measured 2026-10-25, Sesión 019: word-level ES decisions at
# chance level, conf 0.12-0.16).
#
# Platforms:
#   macOS arm64  -> PREBUILT `laya` binary (ggmlc release, Metal) + source
#                   fallback if the binary does not run. No compiler needed.
#   Linux/other  -> build `laya` from the ggmlc source tarball (CPU).
# Measured on the phone (Helio G80, CPU): RSS 516-571 MB, 1.1-2.5 s/decision.
# On a Mac (Metal) upstream measures ~33 ms/decision — the same probes run
# unchanged (tests/laya_probe.py, tests/corrector_eval.py).
#
# WARNING (memory, phone only): do not keep whisper-small (758 MB) + Laya
# resident at the same time on the Galaxy A22 (1.3+ GB against 1.7-2.2 GB
# free; the MediaTek kernel panicked under that class of pressure, MODELOS
# §5). Run the second engine sequentially. Not a concern on a Mac.
#
# Builds/fetches (sha256 pinned, verified 2026-10-25):
#   ggmlc v0.9.7 tarball        -> var/tmp/ggmlc (source build path)
#   laya-macos-arm64-metal.tgz  -> var/bin/laya  (macOS arm64 prebuilt path)
#   mys/laya-multilingual-GGUF laya_multilingual_q8_0.gguf
#     -> var/models/laya-multilingual/  (345 MB; mmBERT 322M, ES/100+ idiomas)
#   ggml-org/Laya-GGUF Laya-Q8_0.gguf
#     -> var/models/laya/               (429 MB; ModernBERT, inglés)
#
# Usage:
#   scripts/fetch-laya.sh [--offline] [--skip-english] [--from-source]
#
# Idempotent: skips work already done; --offline fails instead of downloading.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OS=$(uname -s)
MACHINE=$(uname -m)

GGMLC_VER=0.9.7
GGMLC_URL=https://github.com/monatis/ggmlc/releases/download/v$GGMLC_VER/ggmlc-$GGMLC_VER.tar.gz
GGMLC_SHA=2081c3fc6c8c339198339bb083f12ebae803ad89e3a3ece58c52af2b73a04020
GGMLC_DIR=$ROOT/var/tmp/ggmlc

MAC_URL=https://github.com/monatis/ggmlc/releases/download/v$GGMLC_VER/laya-macos-arm64-metal.tar.gz
MAC_SHA=4855556cf8c9a395a3bbd17c2996d0f00fdb80ff01983758eb739df12501b849
PREBUILT_BIN=$ROOT/var/bin/laya

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
FROM_SOURCE=0

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case $1 in
        --offline)      OFFLINE=1; shift ;;
        --skip-english) SKIP_ENGLISH=1; shift ;;
        --from-source)  FROM_SOURCE=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "fetch-laya: unknown argument: $1" >&2; exit 2 ;;
    esac
done

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

need curl; need sha256sum 2>/dev/null || need shasum; need tar

sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$1" | cut -d' ' -f1; }

fetch() { # fetch <url> <dest> <sha>
    [ -f "$2" ] && [ "$(sha_of "$2")" = "$3" ] && { say "cached: $2"; return 0; }
    [ "$OFFLINE" = 1 ] && die "missing $2 and --offline was requested"
    say "fetch: $1"
    curl -sSL -o "$2" "$1"
    [ "$(sha_of "$2")" = "$3" ] || die "sha256 mismatch: $2"
}

# ---------------------------------------------------------------- laya CLI
LAYA_BIN=""
if [ "$OS" = "Darwin" ] && [ "$MACHINE" = "arm64" ] && [ "$FROM_SOURCE" = 0 ]; then
    # prebuilt Metal binary (no compiler needed)
    if [ -x "$PREBUILT_BIN" ]; then
        say "cached: prebuilt laya (macOS arm64)"
    else
        [ "$OFFLINE" = 1 ] && die "prebuilt laya missing and --offline was requested"
        tmp=$(mktemp -d)
        fetch "$MAC_URL" "$tmp/laya-macos.tar.gz" "$MAC_SHA"
        tar xzf "$tmp/laya-macos.tar.gz" -C "$tmp"
        mkdir -p "$ROOT/var/bin"
        cp "$tmp/laya" "$PREBUILT_BIN"
        chmod 755 "$PREBUILT_BIN"
        rm -rf "$tmp"
        say "installed: $PREBUILT_BIN (macOS arm64 Metal)"
    fi
    LAYA_BIN=$PREBUILT_BIN
else
    # source build (Linux, macOS x86_64, --from-source)
    need cmake; need make; need g++
    if [ -d "$GGMLC_DIR" ]; then
        say "cached: ggmlc $GGMLC_VER source"
    else
        [ "$OFFLINE" = 1 ] && die "ggmlc $GGMLC_VER missing and --offline was requested"
        say "fetch: ggmlc $GGMLC_VER"
        tmp=$(mktemp)
        curl -sSL -o "$tmp" "$GGMLC_URL"
        [ "$(sha_of "$tmp")" = "$GGMLC_SHA" ] || die "sha256 mismatch: ggmlc tarball"
        mkdir -p "$GGMLC_DIR"
        tar xzf "$tmp" -C "$GGMLC_DIR" --strip-components=1
        rm -f "$tmp"
    fi

    # musl patch (idempotent): server.cpp uses struct timeval without
    # <sys/time.h> (glibc pulls it in transitively, musl does not). Inserted
    # with python3: BSD sed (macOS) and GNU sed differ here.
    if grep -q '#include <sys/time.h>' "$GGMLC_DIR/examples/laya/src/server.cpp" 2>/dev/null; then
        say "cached: musl patch"
    else
        need python3
        python3 - "$GGMLC_DIR/examples/laya/src/server.cpp" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
src = src.replace('#include <sys/socket.h>',
                  '#include <sys/socket.h>\n#include <sys/time.h>', 1)
open(path, 'w').write(src)
PYEOF
        say "patched: examples/laya/src/server.cpp (+ <sys/time.h>)"
    fi

    if [ -x "$GGMLC_DIR/build/examples/laya/laya" ]; then
        say "cached: laya build"
    else
        [ "$OFFLINE" = 1 ] && die "laya build missing and --offline was requested"
        say "build: laya (-j2)"
        cmake -S "$GGMLC_DIR" -B "$GGMLC_DIR/build" -DCMAKE_BUILD_TYPE=Release \
            -DGGMLC_BUILD_EXAMPLES=ON >/dev/null
        cmake --build "$GGMLC_DIR/build" --target laya -j2
    fi
    LAYA_BIN=$GGMLC_DIR/build/examples/laya/laya
fi

# ---------------------------------------------------------------- models
mkdir -p "$MULTI_DIR"
fetch "$MULTI_URL/$MULTI_GGUF" "$MULTI_DIR/$MULTI_GGUF" "$MULTI_SHA"

if [ "$SKIP_ENGLISH" = 1 ]; then
    say "skipped: english checkpoint (--skip-english)"
else
    mkdir -p "$EN_DIR"
    fetch "$EN_URL/$EN_GGUF" "$EN_DIR/$EN_GGUF" "$EN_SHA"
fi

say "done. judge server (spanish):"
say "  $LAYA_BIN serve $MULTI_DIR/$MULTI_GGUF --port 8092"
say "probe:"
say "  python3 tests/corrector_eval.py --judge http://127.0.0.1:8092"
