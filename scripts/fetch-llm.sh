#!/bin/sh
# fetch-llm — llama.cpp (pinned) + Qwen3-1.7B Q4_K_M for offline transcript
# correction experiments (second pass / rescoring).
#
# Why: small local LLM to correct ASR output (punctuation, accents, obvious
# word errors). Measured on this device (Helio G80): prompt ~8 t/s, generation
# ~3-4 t/s, min 728 MB free RAM with `-c 2048 -t 2`. NOT for live use.
#
# WARNING (2026-10-25 incident): loading the 1.1 GB GGUF with the system under
# memory pressure (page cache from fresh downloads + default ctx) exhausted
# RAM+zram and the MediaTek kernel panicked (bootreason=kernel_panic, pstore
# call trace: OOM in f2fs filemap fault under llama-cli). Always run llama
# with `-c 2048 -t 2` after `echo 3 > /proc/sys/vm/drop_caches`, and watch
# `free -m` during the first load. See docs/OPERACION.md.
#
# Requires: git, cmake, g++, make, curl, sha256sum and linux-headers
# (musl: `apk add linux-headers` — llama.cpp's common/arg.cpp includes
# <linux/limits.h>, absent on a bare Alpine chroot).
#
# Builds:
#   llama.cpp v0.7.0 (tag, commit 620d2225cc436ab0b001e3200e590e3b286ef9ab)
#     -> var/tmp/llama.cpp (unversioned, like sherpa-onnx)
# Model (sha256 pinned; verified 2026-10-25):
#   unsloth/Qwen3-1.7B-GGUF Qwen3-1.7B-Q4_K_M.gguf -> var/models/qwen3-1.7b/
#
# Usage:
#   scripts/fetch-llm.sh [--offline] [--jobs N]
#
# Idempotent: skips work already done; --offline fails instead of downloading.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TAG=v0.7.0
COMMIT=620d2225cc436ab0b001e3200e590e3b286ef9ab
REPO=https://github.com/ggml-org/llama.cpp.git
DIR=$ROOT/var/tmp/llama.cpp
MODEL_DIR=$ROOT/var/models/qwen3-1.7b
BASE_URL=https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/main
GGUF=Qwen3-1.7B-Q4_K_M.gguf
GGUF_SHA=b139949c5bd74937ad8ed8c8cf3d9ffb1e99c866c823204dc42c0d91fa181897
GGUF_SZ=1107409472
OFFLINE=0
JOBS=2

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case $1 in
        --offline) OFFLINE=1; shift ;;
        --jobs)    JOBS=${2:?--jobs needs a value}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "fetch-llm: unknown argument: $1" >&2; exit 2 ;;
    esac
done

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

need git; need cmake; need make; need curl; need sha256sum; need g++
[ -f /usr/include/linux/limits.h ] || die "linux-headers missing (apk add linux-headers)"

# -- llama.cpp source (pinned tag + commit)
if [ -d "$DIR/.git" ] && [ "$(git -C "$DIR" rev-parse HEAD 2>/dev/null)" = "$COMMIT" ]; then
    say "cached: llama.cpp $TAG ($COMMIT)"
else
    [ "$OFFLINE" = 1 ] && die "llama.cpp $TAG missing and --offline was requested"
    say "clone: llama.cpp $TAG"
    rm -rf "$DIR"
    git clone --depth 1 --branch "$TAG" "$REPO" "$DIR"
    [ "$(git -C "$DIR" rev-parse HEAD)" = "$COMMIT" ] || die "cloned commit mismatch"
fi

# -- build (once)
if [ -x "$DIR/build/bin/llama-cli" ]; then
    say "cached: llama.cpp build"
else
    [ "$OFFLINE" = 1 ] && die "llama.cpp build missing and --offline was requested"
    say "build: llama.cpp (-j$JOBS; keep JOBS low: RAM-constrained device)"
    cmake -S "$DIR" -B "$DIR/build" -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=ON
    make -C "$DIR/build" -j"$JOBS"
fi

# -- model (pinned)
mkdir -p "$MODEL_DIR"
out="$MODEL_DIR/$GGUF"
if [ -f "$out" ] && [ "$(wc -c < "$out" | tr -d ' ')" = "$GGUF_SZ" ] && \
   [ "$(sha256sum "$out" | cut -d' ' -f1)" = "$GGUF_SHA" ]; then
    say "cached: $GGUF"
else
    [ "$OFFLINE" = 1 ] && die "model missing/corrupt and --offline was requested"
    say "download: $GGUF ($GGUF_SZ bytes)"
    curl -fL --retry 3 --connect-timeout 15 -o "$out.part" "$BASE_URL/$GGUF"
    got=$(sha256sum "$out.part" | cut -d' ' -f1)
    if [ "$got" != "$GGUF_SHA" ]; then
        rm -f "$out.part"
        die "checksum mismatch for $GGUF: got $got, want $GGUF_SHA"
    fi
    mv "$out.part" "$out"
fi

say
say "ready. Run a correction (SAFE SETTINGS — see warning above):"
say "  echo 3 > /proc/sys/vm/drop_caches   # as root, free page cache first"
say "  var/tmp/llama.cpp/build/bin/llama-cli \\"
say "      -m \$PWD/var/models/qwen3-1.7b/$GGUF -t 2 -c 2048 --temp 0.1 -st -rea off \\"
say "      -sys 'Fix ONLY words that are likely speech-recognition mistakes. Reply with the corrected text only.' \\"
say "      -p '<transcript>'"
