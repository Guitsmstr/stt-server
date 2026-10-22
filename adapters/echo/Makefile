CXX ?= g++
CXXFLAGS ?= -O2 -std=c++17 -Wall -Wextra

stt-adapter-echo: echo.cc
	$(CXX) $(CXXFLAGS) -o $@ $<

clean:
	rm -f stt-adapter-echo

.PHONY: clean
