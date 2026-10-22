# Define a directory for dependencies in the user's home folder
DEPS_DIR := $(HOME)/VoiceInk-Dependencies
WHISPER_CPP_DIR := $(DEPS_DIR)/whisper.cpp
FRAMEWORK_PATH := $(WHISPER_CPP_DIR)/build-apple/whisper.xcframework
WHISPER_COMMIT := 0ec0845110dc934911dc48e8c5beb5ad3189b3f3
BUILD_DIR := $(CURDIR)/build.noindex
LOCAL_DERIVED_DATA := $(BUILD_DIR)/local-derived-data
DEBUG_DERIVED_DATA := $(BUILD_DIR)/debug-derived-data
LOCAL_APP_OUTPUT := $(BUILD_DIR)/AgentFlow.app

.PHONY: all clean whisper setup build local check healthcheck help dev run

# Default target
all: check build

# Development workflow
dev: build run

# Prerequisites
check:
	@echo "Checking prerequisites..."
	@command -v git >/dev/null 2>&1 || { echo "git is not installed"; exit 1; }
	@command -v xcodebuild >/dev/null 2>&1 || { echo "xcodebuild is not installed (need Xcode)"; exit 1; }
	@command -v swift >/dev/null 2>&1 || { echo "swift is not installed"; exit 1; }
	@echo "Prerequisites OK"

healthcheck: check

# Build process
whisper:
	@mkdir -p "$(DEPS_DIR)"
	@if [ -d "$(WHISPER_CPP_DIR)" ] && [ "$$(git -C "$(WHISPER_CPP_DIR)" rev-parse HEAD)" != "$(WHISPER_COMMIT)" ]; then \
		echo "Existing whisper.cpp is not the tested revision $(WHISPER_COMMIT); preserve it and use a separate dependency checkout."; exit 1; \
	fi
	@if [ ! -d "$(FRAMEWORK_PATH)" ]; then \
		echo "Building whisper.xcframework in $(DEPS_DIR)..."; \
		if [ ! -d "$(WHISPER_CPP_DIR)" ]; then \
			git clone https://github.com/ggml-org/whisper.cpp.git "$(WHISPER_CPP_DIR)" && \
			git -C "$(WHISPER_CPP_DIR)" checkout --detach "$(WHISPER_COMMIT)" || exit 1; \
		fi; \
		cd "$(WHISPER_CPP_DIR)" && ./build-xcframework.sh; \
	else \
		echo "whisper.xcframework already built in $(DEPS_DIR), skipping build"; \
	fi

setup: whisper
	@echo "Whisper framework is ready at $(FRAMEWORK_PATH)"
	@echo "Please ensure your Xcode project references the framework from this new location."

build: setup
	xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug -derivedDataPath "$(DEBUG_DERIVED_DATA)" CODE_SIGN_IDENTITY="" build

# Build for local use without Apple Developer certificate
local: check setup
	@echo "Building Agent Flow for local use (no Apple Developer certificate required)..."
	xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
		-derivedDataPath "$(LOCAL_DERIVED_DATA)" \
		-xcconfig LocalBuild.xcconfig \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=YES \
		DEVELOPMENT_TEAM="" \
		CODE_SIGN_ENTITLEMENTS="$(CURDIR)/VoiceInk/VoiceInk.local.entitlements" \
		SWIFT_ACTIVE_COMPILATION_CONDITIONS='$$(inherited) LOCAL_BUILD' \
		build
	@# AgentFlow keeps the existing bundle ID so users retain their settings and permissions.
	@APP_PATH="$(LOCAL_DERIVED_DATA)/Build/Products/Debug/AgentFlow.app" && \
	if [ -d "$$APP_PATH" ]; then \
		echo "Copying AgentFlow.app to $(LOCAL_APP_OUTPUT)..."; \
		if [ -e "$(LOCAL_APP_OUTPUT)" ]; then echo "Output already exists; choose a fresh LOCAL_APP_OUTPUT path."; exit 1; fi; \
		mkdir -p "$$(dirname "$(LOCAL_APP_OUTPUT)")"; \
		ditto "$$APP_PATH" "$(LOCAL_APP_OUTPUT)"; \
		xattr -cr "$(LOCAL_APP_OUTPUT)"; \
		echo ""; \
		echo "Build complete! App saved to: $(LOCAL_APP_OUTPUT)"; \
		echo "Run with: open $(LOCAL_APP_OUTPUT)"; \
		echo ""; \
		echo "Limitations of local builds:"; \
		echo "  - No iCloud dictionary sync"; \
		echo "  - No automatic updates (pull new code and rebuild to update)"; \
	else \
		echo "Error: Could not find built AgentFlow.app at $$APP_PATH"; \
		exit 1; \
	fi

# Run application
run:
	@if [ -d "$(LOCAL_APP_OUTPUT)" ]; then \
		echo "Opening build.noindex/AgentFlow.app..."; \
		open "$(LOCAL_APP_OUTPUT)"; \
	else \
		APP_PATH="$(DEBUG_DERIVED_DATA)/Build/Products/Debug/AgentFlow.app" && \
		if [ -d "$$APP_PATH" ]; then \
			echo "Found app at: $$APP_PATH"; \
			open "$$APP_PATH"; \
		else \
			echo "AgentFlow.app not found. Please run 'make build' or 'make local' first."; \
			exit 1; \
		fi; \
	fi

# Cleanup
clean:
	@echo "Build outputs live in $(BUILD_DIR). Remove only your chosen inactive output after inspecting it. Shared dependencies are preserved."

# Help
help:
	@echo "Available targets:"
	@echo "  check/healthcheck  Check if required CLI tools are installed"
	@echo "  whisper            Clone and build whisper.cpp XCFramework"
	@echo "  setup              Copy whisper XCFramework to VoiceInk project"
	@echo "  build              Build the VoiceInk Xcode project"
	@echo "  local              Build for local use (no Apple Developer certificate needed)"
	@echo "  run                Launch the built VoiceInk app"
	@echo "  dev                Build and run the app (for development)"
	@echo "  all                Run full build process (default)"
	@echo "  clean              Remove build artifacts"
	@echo "  help               Show this help message"
