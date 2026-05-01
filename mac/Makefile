.PHONY: project build test clean run

# All Swift sources xcodegen scans — regenerate the project when this set
# changes (file added or removed, e.g. after a merge), or when project.yml
# or Local.xcconfig change. mtime on existing files also triggers regen,
# but xcodegen is fast (~0.5s) so the cost is negligible.
SWIFT_SOURCES := $(shell find VoiceKeyboard -name '*.swift' -type f 2>/dev/null)

# Bootstrap per-machine signing config from sample if missing
Local.xcconfig:
	@cp Local.xcconfig.sample Local.xcconfig
	@echo "Created mac/Local.xcconfig — edit it and set DEVELOPMENT_TEAM, then re-run."
	@exit 1

# Real file target — Make compares timestamps and only runs xcodegen when
# any input is newer than the generated .pbxproj.
VoiceKeyboard.xcodeproj/project.pbxproj: project.yml Local.xcconfig $(SWIFT_SOURCES)
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

# Clean build artifacts
clean:
	rm -rf DerivedData build
	cd Packages/VoiceKeyboardCore && swift package clean

# Build and launch the .app
run: build
	APP_PATH=$$(xcodebuild -project VoiceKeyboard.xcodeproj \
	  -scheme VoiceKeyboard -showBuildSettings 2>/dev/null | \
	  awk -F' = ' '/BUILT_PRODUCTS_DIR/ {print $$2; exit}') ; \
	open "$$APP_PATH/VoiceKeyboard.app"
