SHELL := /bin/bash
BUILD_DIR := build
GO := go
WHISPER_PREFIX := /opt/homebrew/opt/whisper-cpp
DEEPFILTER_DIR := vendor/deepfilter

# Used by CGo to find headers and libraries
export CGO_CFLAGS  := -I$(WHISPER_PREFIX)/include -I$(CURDIR)/$(DEEPFILTER_DIR)/include
export CGO_LDFLAGS := -L$(WHISPER_PREFIX)/lib -lwhisper -L$(CURDIR)/$(DEEPFILTER_DIR)/lib/macos-arm64 -ldf
export DYLD_LIBRARY_PATH := $(WHISPER_PREFIX)/lib:$(CURDIR)/$(DEEPFILTER_DIR)/lib/macos-arm64:$(DYLD_LIBRARY_PATH)

.PHONY: bootstrap build build-cli build-dylib test test-unit test-integration clean rebuild-denoise

bootstrap:
	@command -v go >/dev/null || (echo "Go not installed. Run: brew install go" && exit 1)
	@command -v xcodebuild >/dev/null || (echo "Xcode required" && exit 1)
	@test -f $(WHISPER_PREFIX)/lib/libwhisper.dylib || (echo "whisper-cpp not installed. Run: brew install whisper-cpp" && exit 1)
	@test -f $(DEEPFILTER_DIR)/lib/macos-arm64/libdf.dylib || (echo "vendored libdf.dylib missing. See BUILDING_DENOISE.md" && exit 1)
	$(GO) mod download
	@echo "Bootstrap OK"

build: build-cli build-dylib

build-cli:
	mkdir -p $(BUILD_DIR)
	$(GO) build -o $(BUILD_DIR)/vkb-cli ./cmd/vkb-cli

build-dylib:
	mkdir -p $(BUILD_DIR)
	$(GO) build -buildmode=c-shared -o $(BUILD_DIR)/libvkb.dylib ./cmd/libvkb

test: test-unit

test-unit:
	$(GO) test ./internal/...

test-integration:
	$(GO) test -tags=integration ./test/integration/...

clean:
	rm -rf $(BUILD_DIR)

rebuild-denoise:
	@echo "Maintainer-only target. See BUILDING_DENOISE.md."
	@exit 1
