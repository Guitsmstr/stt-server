# stt-adapter-sherpa — sherpa-onnx streaming zipformer (Stage 5, D14).
#
# Links statically against a sherpa-onnx build from source
# (var/tmp/sherpa-onnx, unversioned; see PLAN §Stage 5) and dynamically
# against the system libonnxruntime (Alpine repos; prebuilt sherpa-onnx
# tarballs are glibc and do not run on musl).
#
# sherpa-onnx build (once):
#   cmake -S var/tmp/sherpa-onnx -B var/tmp/sherpa-onnx/build \
#         -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
#         -DCMAKE_CXX_FLAGS="-include cstdint" \
#         -DSHERPA_ONNX_ENABLE_PYTHON=OFF -DSHERPA_ONNX_ENABLE_TESTS=OFF \
#         -DSHERPA_ONNX_ENABLE_CHECK=OFF -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
#         -DSHERPA_ONNX_ENABLE_JNI=OFF -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF \
#         -DSHERPA_ONNX_ENABLE_TTS=OFF -DSHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=OFF \
#         -DSHERPA_ONNX_ENABLE_BINARY=OFF -DSHERPA_ONNX_BUILD_C_API_EXAMPLES=OFF
#   make -C var/tmp/sherpa-onnx/build -j2
# (GCC 15/musl: -include cstdint — upstream headers miss <cstdint>.)

all: stt-adapter-sherpa

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

stt-adapter-sherpa: sherpa.cc
	$(CXX) $(CXXFLAGS) $(SHERPA_CFLAGS) $(ORT_CFLAGS) -o $@ $< \
		$(SHERPA_LIBS) $(ORT_LIBS) $(SYSLIBS)

clean:
	rm -f stt-adapter-sherpa

.PHONY: clean
