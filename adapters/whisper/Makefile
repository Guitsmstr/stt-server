# stt-adapter-whisper — sherpa-onnx offline Whisper (accuracy evaluation /
# offline second pass; NOT a live dictation engine).
#
# Links exactly like adapters/sherpa against the same sherpa-onnx build
# from source (var/tmp/sherpa-onnx) and the system libonnxruntime — see
# adapters/sherpa/Makefile for the full build recipe of sherpa-onnx.
#
# Build sherpa-onnx once (shared with adapters/sherpa):
#   sh -c 'make -C ../../var/tmp/sherpa-onnx/build -j2'   # or the cmake
#   recipe documented in adapters/sherpa/Makefile header.
# Then:
#   make -C adapters/whisper

all: stt-adapter-whisper

CXX ?= g++
CXXFLAGS ?= -O2 -std=c++17 -Wall -Wextra
ORT_CFLAGS ?= -I/usr/include/onnxruntime
SHERPA_DIR ?= ../../var/tmp/sherpa-onnx
SHERPA_CFLAGS ?= -I$(SHERPA_DIR)
SHERPA_LIB ?= $(SHERPA_DIR)/build/lib
# Order matters: dependents before dependencies.
SHERPA_LIBS ?= $(SHERPA_LIB)/libsherpa-onnx-c-api.a \
               $(SHERPA_LIB)/libsherpa-onnx-core.a \
               $(SHERPA_LIB)/libsherpa-onnx-kaldifst-core.a \
               $(SHERPA_LIB)/libkaldi-decoder-core.a \
               $(SHERPA_LIB)/libsherpa-onnx-fst.a \
               $(SHERPA_LIB)/libsherpa-onnx-fstfar.a \
               $(SHERPA_LIB)/libkaldi-native-fbank-core.a \
               $(SHERPA_LIB)/libssentencepiece_core.a \
               $(SHERPA_LIB)/libkissfft-float.a
ORT_LIBS ?= -lonnxruntime
SYSLIBS ?= -lpthread -ldl -lm

stt-adapter-whisper: whisper.cc
	$(CXX) $(CXXFLAGS) $(SHERPA_CFLAGS) $(ORT_CFLAGS) -o $@ $< \
		$(SHERPA_LIBS) $(ORT_LIBS) $(SYSLIBS)

clean:
	rm -f stt-adapter-whisper

.PHONY: all clean
