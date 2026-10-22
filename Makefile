.PHONY: all core adapters models test test-stage2 test-stage3 test-stage4 clean

all: core adapters

core:
	cd core && go vet ./... && go build -o ../var/bin/stt ./cmd/stt

adapters:
	$(MAKE) -C adapters/echo
	$(MAKE) -C adapters/moonshine

models:
	sh scripts/fetch-model.sh

test: all
	cd core && go test ./...
	sh tests/run-stage1-tests.sh

test-stage2: all
	sh tests/run-stage2-tests.sh

test-stage3: all
	sh tests/run-stage3-tests.sh

test-stage4: all
	sh tests/run-stage4-tests.sh

clean:
	rm -f var/bin/stt
	$(MAKE) -C adapters/echo clean
	$(MAKE) -C adapters/moonshine clean
