#!/bin/sh
# fetch-model.sh — idempotent model cache for the stt project.
#
# Models (pinned by sha256; a second run works with --offline):
#   tiny        Moonshine tiny (default) -> var/models/moonshine-tiny/
#               adapters/moonshine/stt-adapter-moonshine
#   kroko-en    streaming zipformer EN, kroko 2025-08-06 (24 kHz, float)
#               -> var/models/sherpa-zipformer-en-kroko/
#               adapters/sherpa/stt-adapter-sherpa (recommended EN engine:
#               punctuation + casing, better WER and RTF than the 2023 model)
#   kroko-es    streaming zipformer ES, kroko 2025-08-06 (22.05 kHz, float)
#               -> var/models/sherpa-zipformer-es/
#               adapters/sherpa/stt-adapter-sherpa
#   zipformer-en streaming zipformer EN 2023-06-26 (16 kHz, int8)
#               -> var/models/sherpa-zipformer-en/
#               fallback EN engine (UPPERCASE output, older training)
#
# Kroko models: Banafo/Kroko-ASR community exports (CC-BY-SA), repackaged by
# csukuangfj. The audio contract stays 16 kHz; sherpa-onnx resamples to the
# model rate internally (sherpa.cc --sample-rate).
#
# Idempotent: files already present with the pinned sha256 are not downloaded
# again, so a second run works with --offline and does not touch the network.
#
# Usage:
#   scripts/fetch-model.sh [--model tiny|kroko-en|kroko-es|zipformer-en]
#                          [--dest DIR] [--offline]
#
# Assets (moonshine tiny): https://huggingface.co/moonshine-ai/moonshine
#   onnx/merged/tiny/float/{encoder_model,decoder_model_merged}.onnx
#   ctranslate2/tiny/tokenizer.json  (same tokenizer used by the ONNX export)
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MODEL=tiny
DEST=
OFFLINE=0
BASE_URL="https://huggingface.co/moonshine-ai/moonshine/resolve/main"

usage() {
    sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'
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

if [ "$MODEL" != "tiny" ] && [ "$MODEL" != "kroko-en" ] && \
   [ "$MODEL" != "kroko-es" ] && [ "$MODEL" != "zipformer-en" ]; then
    echo "fetch-model: unknown model '$MODEL' (tiny|kroko-en|kroko-es|zipformer-en)" >&2
    exit 2
fi

case $MODEL in
    tiny)         DEST=${DEST:-$ROOT/var/models/moonshine-tiny} ;;
    kroko-en)     DEST=${DEST:-$ROOT/var/models/sherpa-zipformer-en-kroko} ;;
    kroko-es)     DEST=${DEST:-$ROOT/var/models/sherpa-zipformer-es} ;;
    zipformer-en) DEST=${DEST:-$ROOT/var/models/sherpa-zipformer-en} ;;
esac
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

if [ "$MODEL" = "tiny" ]; then
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
elif [ "$MODEL" = "kroko-en" ] || [ "$MODEL" = "kroko-es" ]; then
    # sherpa-onnx streaming zipformer (kroko 2025-08-06, float). sha256 pinned
    # from the csukuangfj HF repos; verified 2026-10-23 against the files used
    # in the Sesión 009 precision tests.
    if [ "$MODEL" = "kroko-en" ]; then
        HF=csukuangfj/sherpa-onnx-streaming-zipformer-en-kroko-2025-08-06
        ENC_SHA=d4881c57449d581e0770fd53fa66c2fdc6cd167d92ece7c715e603defc96d9d4
        ENC_SZ=70092599
        DEC_SHA=455ba38466fce8d5a57e7db68a323b684079ca4d9e1dd93a740d9b2429aae3b1
        JOIN_SHA=d406f616736350e2a7df3e39398b78eb2fc1a2ca6973a19d3853fa3227e25b52
        TOK_SHA=396dbeb5f4858875690716084f54e90d339679d0ba3e6b5b584f3d7589254d2d
        TOK_SZ=6310
    else
        HF=csukuangfj/sherpa-onnx-streaming-zipformer-es-kroko-2025-08-06
        ENC_SHA=2d9f5ef87d1a5257f8a6687e21501c56f3aa2fcbfcfab9364dcc4ce4e06ae81b
        ENC_SZ=154878102
        DEC_SHA=d4ce176b94b25f7acc88717bc3f704fcf5d6e131aaac2e0cabab3885541181ee
        JOIN_SHA=dae35df88d676e320fcdb99217328e66dcf722bf11b0f2459e14ddb5b982ded5
        TOK_SHA=1be5e0a58e05d06d327df4c6b7b5e4f8aba01da6981eb016fcaceafc6a56680f
        TOK_SZ=6385
    fi
    BASE_URL="https://huggingface.co/$HF/resolve/main"
    download "$BASE_URL/encoder.onnx" encoder.onnx "$ENC_SHA" "$ENC_SZ"
    download "$BASE_URL/decoder.onnx" decoder.onnx "$DEC_SHA" 617488
    download "$BASE_URL/joiner.onnx" joiner.onnx "$JOIN_SHA" 336817
    download "$BASE_URL/tokens.txt" tokens.txt "$TOK_SHA" "$TOK_SZ"
    # Shared test clip (22.05 kHz) used by the S5.4 Spanish coverage check.
    # Only the ES repo is pinned: the test resamples it to 16 kHz with sox.
    if [ "$MODEL" = "kroko-es" ]; then
        download "$BASE_URL/test_wavs/0.wav" test_wav0.wav \
            49fd2cfa4b62db7068143c582b35de9d31ec2733495ece3611105131d21de06c 235052
    fi
elif [ "$MODEL" = "zipformer-en" ]; then
    # sherpa-onnx streaming zipformer EN 2023-06-26, int8 export (fallback EN
    # engine). sha256 pinned from the local cache, verified 2026-10-23.
    BASE_URL="https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26/resolve/main"
    P=epoch-99-avg-1-chunk-16-left-64
    download "$BASE_URL/encoder-$P.int8.onnx" "encoder-$P.int8.onnx" \
        0d072fd4ef956294ba9db9e9a71a541ac70659095ec4934c8453d8b2fe740187 71082637
    download "$BASE_URL/decoder-$P.int8.onnx" "decoder-$P.int8.onnx" \
        98da299f471e38bb4e1a8df579b8cc9122d6039576a77e357b3c60f17dd83b02 1307236
    download "$BASE_URL/joiner-$P.int8.onnx" "joiner-$P.int8.onnx" \
        d944208d660d67c8d72cd2acaeac971fa5ceb8c80e76c1968148846fedd6e297 259335
    download "$BASE_URL/tokens.txt" tokens.txt \
        49e3c2646595fd907228b3c6787069658f67b17377c60aeb8619c4551b2316fb 5048
fi

echo "model ready: $DEST"
ls -l "$DEST"
