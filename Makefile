.PHONY: all core adapters models test test-stage2 test-stage3 test-soak test-stage4 test-stage5 test-stage6 clean

all: core adapters

core:
	cd core && go vet ./... && go build -o ../var/bin/stt ./cmd/stt && go build -o ../var/bin/sttd ./cmd/sttd

adapters:
	$(MAKE) -C adapters/echo
	$(MAKE) -C adapters/moonshine
	$(MAKE) -C adapters/sherpa

models:
	sh scripts/fetch-model.sh
	sh scripts/fetch-model.sh --model kroko-en
	sh scripts/fetch-model.sh --model kroko-es
	sh scripts/fetch-model.sh --model zipformer-en
	sh scripts/fetch-sherpa.sh

test: all
	cd core && go test ./...
	sh tests/run-stage1-tests.sh

test-stage2: all
	sh tests/run-stage2-tests.sh

test-stage3: all
	sh tests/run-stage3-tests.sh

test-soak: all
	STT_SOAK=1 sh tests/run-stage3-tests.sh

test-stage4: all
	sh tests/run-stage4-tests.sh

test-stage5: all
	sh tests/run-stage5-tests.sh

test-stage6: all
	sh tests/run-stage6-tests.sh

clean:
	rm -f var/bin/stt
	$(MAKE) -C adapters/echo clean
	$(MAKE) -C adapters/moonshine clean
	$(MAKE) -C adapters/sherpa clean
