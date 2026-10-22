.PHONY: all core adapters test clean

all: core adapters

core:
	cd core && go vet ./... && go build -o ../var/bin/stt ./cmd/stt

adapters:
	$(MAKE) -C adapters/echo

test: all
	cd core && go test ./...
	sh tests/run-stage1-tests.sh

clean:
	rm -f var/bin/stt
	$(MAKE) -C adapters/echo clean
