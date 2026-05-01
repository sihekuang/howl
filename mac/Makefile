.PHONY: project build test clean clean-all run

# All Swift sources xcodegen scans — regenerate the project when this set
# changes (file added or removed, e.g. after a merge), or when project.yml
# or Configs/SharedSettings.xcconfig change. mtime on existing files also triggers
# regen, but xcodegen is fast (~0.5s) so the cost is negligible.
SWIFT_SOURCES := $(shell find VoiceKeyboard -name '*.swift' -type f 2>/dev/null)

# Real file target — Make compares timestamps and only runs xcodegen when
# any input is newer than the generated .pbxproj.
VoiceKeyboard.xcodeproj/project.pbxproj: project.yml Configs/SharedSettings.xcconfig $(SWIFT_SOURCES)
	xcodegen generate

# Phony alias so `make project` keeps working as before, but now skips
# the xcodegen run when everything is up to date.
project: VoiceKeyboard.xcodeproj/project.pbxproj

# Build the .app
build: project
	xcodebuild -project VoiceKeyboard.xcodeproj \
	  -scheme VoiceKeyboard -configuration Debug build

# Run package tests (no Xcode required)
test:
	cd Packages/VoiceKeyboardCore && swift test

# Clean Mac-side build artefacts. Xcode keeps DerivedData under
# ~/Library/Developer/Xcode/DerivedData (NOT a local mac/DerivedData
# dir, despite the name in older docs), so we glob for our project's
# hashed dirs there. `swift package clean` resets the SwiftPM build
# dir used by `make test`.
clean:
	rm -rf $(HOME)/Library/Developer/Xcode/DerivedData/VoiceKeyboard-*
	rm -f ../core/build/libvkb.dylib ../core/build/libvkb.h
	cd Packages/VoiceKeyboardCore && swift package clean

# Same as `clean` plus the cheap Go binaries (vkb-cli, vkb-enroll).
# Still preserves TSE models + Python venv — call `make distclean`
# in core/ if you actually want those gone.
clean-all: clean
	cd ../core && $(MAKE) clean

# Build and launch the .app
run: build
	APP_PATH=$$(xcodebuild -project VoiceKeyboard.xcodeproj \
	  -scheme VoiceKeyboard -showBuildSettings 2>/dev/null | \
	  awk -F' = ' '/BUILT_PRODUCTS_DIR/ {print $$2; exit}') ; \
	open "$$APP_PATH/VoiceKeyboard.app"
