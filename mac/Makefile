.PHONY: project build test clean run

# Regenerate Xcode project from project.yml
project:
	xcodegen generate

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
