# stt-adapter-whisper — sherpa-onnx offline Whisper (accuracy evaluation /
# offline second pass; NOT a live dictation engine).
#
# Links exactly like adapters/sherpa against the same sherpa-onnx build
# from source (var/tmp/sherpa-onnx) and the system libonnxruntime — see
# adapters/sherpa/Makefile for the full build recipe of sherpa-onnx.
#
# Build sherpa-onnx once (shared with adapters/sherpa):
#   sh scripts/fetch-sherpa.sh    # macOS arm64: pinned prebuilt static libs
#                                 # Linux/Alpine: source build via cmake (the
#                                 # recipe is in adapters/sherpa/Makefile)
# Then:
#   make -C adapters/whisper

all: stt-adapter-whisper

UNAME_S := $(shell uname -s)

CXX ?= g++
CXXFLAGS ?= -O2 -std=c++17 -Wall -Wextra
SHERPA_DIR ?= ../../var/tmp/sherpa-onnx
SHERPA_CFLAGS ?= -I$(SHERPA_DIR)
SHERPA_LIB ?= $(SHERPA_DIR)/build/lib

# Platform link sets. On macOS, scripts/fetch-sherpa.sh unpacks k2-fsa's
# pinned osx-arm64 static-lib release: it bundles libonnxruntime.a plus the
# piper/espeak/ucd archives that sherpa-onnx-core references, and onnxruntime
# needs the Apple Foundation/CoreFoundation frameworks at link time.
ifeq ($(UNAME_S),Darwin)
ORT_CFLAGS ?=
SHERPA_EXTRA ?= $(SHERPA_LIB)/libpiper_phonemize.a \
                $(SHERPA_LIB)/libespeak-ng.a \
                $(SHERPA_LIB)/libucd.a
ORT_LIBS ?= $(SHERPA_LIB)/libonnxruntime.a
SYSLIBS ?= -lpthread -ldl -lm -framework Foundation -framework CoreFoundation
else
ORT_CFLAGS ?= -I/usr/include/onnxruntime
SHERPA_EXTRA ?=
ORT_LIBS ?= -lonnxruntime
SYSLIBS ?= -lpthread -ldl -lm
endif

# Order matters: dependents before dependencies.
SHERPA_LIBS ?= $(SHERPA_LIB)/libsherpa-onnx-c-api.a \
               $(SHERPA_LIB)/libsherpa-onnx-core.a \
               $(SHERPA_EXTRA) \
               $(SHERPA_LIB)/libsherpa-onnx-kaldifst-core.a \
               $(SHERPA_LIB)/libkaldi-decoder-core.a \
               $(SHERPA_LIB)/libsherpa-onnx-fst.a \
               $(SHERPA_LIB)/libsherpa-onnx-fstfar.a \
               $(SHERPA_LIB)/libkaldi-native-fbank-core.a \
               $(SHERPA_LIB)/libssentencepiece_core.a \
               $(SHERPA_LIB)/libkissfft-float.a

stt-adapter-whisper: whisper.cc
	$(CXX) $(CXXFLAGS) $(SHERPA_CFLAGS) $(ORT_CFLAGS) -o $@ $< \
		$(SHERPA_LIBS) $(ORT_LIBS) $(SYSLIBS)

clean:
	rm -f stt-adapter-whisper

.PHONY: all clean
