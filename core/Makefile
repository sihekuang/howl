SHELL := /bin/bash
BUILD_DIR := build
GO := go
WHISPER_PREFIX := /opt/homebrew/opt/whisper-cpp
DEEPFILTER_DIR := third_party/deepfilter

# Per-package #cgo directives in whisper_cpp.go and deepfilter_cgo.go
# carry their own CFLAGS/LDFLAGS. Nothing needs to be set globally here.

.PHONY: bootstrap build build-cli build-dylib test test-unit test-integration clean clean-models clean-venv distclean rebuild-denoise

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
	$(GO) build -tags="whispercpp deepfilter" -o $(BUILD_DIR)/howl ./cmd/howl

build-dylib:
	mkdir -p $(BUILD_DIR)
	$(GO) build -tags="whispercpp deepfilter" -buildmode=c-shared -o $(BUILD_DIR)/libhowl.dylib ./cmd/libhowl
	install_name_tool -id "@rpath/libhowl.dylib" $(BUILD_DIR)/libhowl.dylib

test: test-unit

test-unit:
	$(GO) test ./internal/...

test-integration:
	$(GO) test -tags=integration ./test/integration/...

# Default `clean`: just the cheap-to-rebuild artefacts (Go binaries +
# generated C header). Preserves the expensive bits — TSE models
# (re-traced via PyTorch in ./enroll.sh, ~30+ min) and the Python venv
# (~2GB pip install). Reach for `clean-models` / `clean-venv` /
# `distclean` when you actually want to nuke those.
clean:
	rm -f $(BUILD_DIR)/libhowl.dylib $(BUILD_DIR)/libhowl.h
	rm -f $(BUILD_DIR)/howl $(BUILD_DIR)/enroll

# Drop the TSE ONNX models. Forces the next Release build (or anything
# that touches TSE) to retrace from PyTorch via ./enroll.sh — ~30+ min.
clean-models:
	rm -rf $(BUILD_DIR)/models

# Drop the PyTorch/asteroid venv. Re-pip-install runs ~5 min the next
# time enroll.sh / scripts/export_tse_model.py runs.
clean-venv:
	rm -rf $(BUILD_DIR)/.venv-tse

# Nuclear: everything under build/. Same as the old `clean`. Useful
# when you suspect cache corruption or want to verify a true cold
# build path.
distclean:
	rm -rf $(BUILD_DIR)

rebuild-denoise:
	@echo "Maintainer-only target. See BUILDING_DENOISE.md."
	@exit 1
