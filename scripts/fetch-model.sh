#!/bin/sh
# fetch-model.sh — idempotent Moonshine model cache for the stt project.
#
# Downloads the ONNX files used by adapters/moonshine/stt-adapter-moonshine
# into var/models/moonshine-<model>/ (never versioned) and generates the
# compact vocab.tsv consumed by the C++ adapter.
#
# Idempotent: files already present with the pinned sha256 are not downloaded
# again, so a second run works with --offline and does not touch the network.
#
# Usage:
#   scripts/fetch-model.sh [--model tiny] [--dest DIR] [--offline]
#
# Assets: https://huggingface.co/moonshine-ai/moonshine
#   onnx/merged/tiny/float/{encoder_model,decoder_model_merged}.onnx
#   ctranslate2/tiny/tokenizer.json  (same tokenizer used by the ONNX export)
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MODEL=tiny
DEST=
OFFLINE=0
BASE_URL="https://huggingface.co/moonshine-ai/moonshine/resolve/main"

usage() {
    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case $1 in
        --model)    MODEL=${2:?--model needs a value}; shift 2 ;;
        --dest)     DEST=${2:?--dest needs a value}; shift 2 ;;
        --offline)  OFFLINE=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          echo "fetch-model: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ "$MODEL" != "tiny" ]; then
    echo "fetch-model: only 'tiny' is pinned in v1 (got '$MODEL')" >&2
    exit 2
fi

DEST=${DEST:-$ROOT/var/models/moonshine-$MODEL}
mkdir -p "$DEST"

sha_of() { sha256sum "$1" | cut -d' ' -f1; }
size_of() { wc -c < "$1" | tr -d ' '; }

# download URL NAME SHA256 SIZE
download() {
    url=$1; name=$2; sha=$3; size=$4
    out="$DEST/$name"
    if [ -f "$out" ] && [ "$(size_of "$out")" = "$size" ] && [ "$(sha_of "$out")" = "$sha" ]; then
        echo "cached: $name"
        return 0
    fi
    if [ "$OFFLINE" = 1 ]; then
        echo "fetch-model: missing/corrupt $name and --offline was requested" >&2
        exit 1
    fi
    echo "download: $name ($size bytes)"
    curl -fL --retry 3 --connect-timeout 15 -o "$out.part" "$url"
    got=$(sha_of "$out.part")
    if [ "$got" != "$sha" ]; then
        rm -f "$out.part"
        echo "fetch-model: checksum mismatch for $name: got $got, want $sha" >&2
        exit 1
    fi
    mv "$out.part" "$out"
}

download "$BASE_URL/onnx/merged/$MODEL/float/encoder_model.onnx" \
    encoder_model.onnx \
    cbbf580f703b2af2137e0f6d14cd87f31cc67bd858bfd8715403a9489982d1a5 30882331

download "$BASE_URL/onnx/merged/$MODEL/float/decoder_model_merged.onnx" \
    decoder_model_merged.onnx \
    4131cef00b62942e9cdef691101f2cc7dbbcd828d71eee8c6c46c28fd051d6cb 78227550

# The tokenizer is not an LFS file on HF; pin the sha256 verified on 2026-10-22.
download "$BASE_URL/ctranslate2/$MODEL/tokenizer.json" \
    tokenizer.json \
    ed2324b3f699d8ba18a4030f33ba205d50b30ff46ff73f2b7d22661cc850efb4 1985534

# vocab.tsv: "id<TAB>token" lines built from tokenizer.json. The adapter only
# needs id -> token bytes (no BPE merges: decoding never merges).
VOCAB="$DEST/vocab.tsv"
if [ -s "$VOCAB" ] && [ "$(wc -l < "$VOCAB" | tr -d ' ')" = 32000 ]; then
    echo "cached: vocab.tsv"
else
    if ! command -v jq >/dev/null 2>&1; then
        echo "fetch-model: jq is required to generate vocab.tsv" >&2
        exit 1
    fi
    echo "generate: vocab.tsv"
    jq -r '.model.vocab | to_entries[] | "\(.value)\t\(.key)"' "$DEST/tokenizer.json" \
        | sort -n -k1,1 > "$VOCAB.part"
    if [ "$(wc -l < "$VOCAB.part" | tr -d ' ')" != 32000 ]; then
        rm -f "$VOCAB.part"
        echo "fetch-model: vocab.tsv generation failed (expected 32000 entries)" >&2
        exit 1
    fi
    mv "$VOCAB.part" "$VOCAB"
fi

echo "model ready: $DEST"
ls -l "$DEST"
