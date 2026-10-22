all: stt-adapter-moonshine

CXX ?= g++
CXXFLAGS ?= -O2 -std=c++17 -Wall -Wextra
ORT_CFLAGS ?= -I/usr/include/onnxruntime
ORT_LIBS ?= -lonnxruntime

stt-adapter-moonshine: moonshine.cc
	$(CXX) $(CXXFLAGS) $(ORT_CFLAGS) -o $@ $< $(ORT_LIBS)

clean:
	rm -f stt-adapter-moonshine

.PHONY: clean
