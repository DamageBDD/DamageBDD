SHELL := /bin/bash

ANDROID_DIR ?= android
IOS_DIR ?= ios

# Android passthrough settings
DEVICE_SERIAL ?=

# iOS project settings
IOS_PROJECT ?= $(IOS_DIR)/DamageMobile.xcodeproj
IOS_CONFIGURATION ?= Debug
IOS_DESTINATION ?= generic/platform=iOS Simulator
IOS_DERIVED_DATA ?= $(CURDIR)/.build/ios

.PHONY: help doctor init build clean \
        android-doctor android-init android-web android-build \
        android-build-damage android-build-ecai \
        android-install-damage android-install-ecai \
        android-run-damage android-run-ecai android-clean \
        run-damage run-ecai build-damage build-ecai \
        ios-doctor ios-generate ios-list ios-build \
        ios-build-damage ios-build-ecai ios-clean

help:
	@printf '%s\n' \
	  'DamageBDD mobile build targets' \
	  '' \
	  'Android (works from Linux/Arch):' \
	  '  make android-doctor' \
	  '  make android-init' \
	  '  make android-build' \
	  '  make android-run-damage [DEVICE_SERIAL=...]' \
	  '  make android-run-ecai   [DEVICE_SERIAL=...]' \
	  '' \
	  'iOS (requires macOS/Xcode):' \
	  '  make ios-generate       # regenerate xcodeproj from ios/project.yml' \
	  '  make ios-list' \
	  '  make ios-build' \
	  '  make ios-build-damage' \
	  '  make ios-build-ecai' \
	  '' \
	  'Compatibility aliases:' \
	  '  make init/build/run-damage/run-ecai -> Android'

# -----------------------------------------------------------------------------
# Convenience/default targets
#
# The existing terminal-first workflow is Android on Arch, so keep the old
# short target names as Android aliases. iOS targets are explicitly prefixed.
# -----------------------------------------------------------------------------
doctor: android-doctor ios-doctor

init: android-init

build: android-build

build-damage: android-build-damage

build-ecai: android-build-ecai

run-damage: android-run-damage

run-ecai: android-run-ecai

clean: android-clean ios-clean

# -----------------------------------------------------------------------------
# Android
#
# mobile/android contains the existing Capacitor workspace:
#   common.mk, damage/, ecai/, scripts/, shared/, Makefile
# -----------------------------------------------------------------------------
android-doctor:
	$(MAKE) -C $(ANDROID_DIR) doctor DEVICE_SERIAL="$(DEVICE_SERIAL)"

android-init:
	$(MAKE) -C $(ANDROID_DIR) init DEVICE_SERIAL="$(DEVICE_SERIAL)"

android-web:
	$(MAKE) -C $(ANDROID_DIR) web DEVICE_SERIAL="$(DEVICE_SERIAL)"

android-build:
	$(MAKE) -C $(ANDROID_DIR) build DEVICE_SERIAL="$(DEVICE_SERIAL)"

android-build-damage:
	$(MAKE) -C $(ANDROID_DIR) build-damage DEVICE_SERIAL="$(DEVICE_SERIAL)"

android-build-ecai:
	$(MAKE) -C $(ANDROID_DIR) build-ecai DEVICE_SERIAL="$(DEVICE_SERIAL)"

android-install-damage:
	$(MAKE) -C $(ANDROID_DIR) install-damage DEVICE_SERIAL="$(DEVICE_SERIAL)"

android-install-ecai:
	$(MAKE) -C $(ANDROID_DIR) install-ecai DEVICE_SERIAL="$(DEVICE_SERIAL)"

android-run-damage:
	$(MAKE) -C $(ANDROID_DIR) run-damage DEVICE_SERIAL="$(DEVICE_SERIAL)"

android-run-ecai:
	$(MAKE) -C $(ANDROID_DIR) run-ecai DEVICE_SERIAL="$(DEVICE_SERIAL)"

android-clean:
	$(MAKE) -C $(ANDROID_DIR) clean

# -----------------------------------------------------------------------------
# iOS
#
# mobile/ios contains one Xcode project with two application schemes/targets:
#   DamageBDD and ECAI.
# project.yml is the XcodeGen source of truth.
# -----------------------------------------------------------------------------
ios-doctor:
	@if [ "$$(uname -s)" != "Darwin" ]; then \
		echo 'iOS: skipped (Xcode builds require macOS)'; \
	elif ! command -v xcodebuild >/dev/null 2>&1; then \
		echo 'iOS: xcodebuild not found' >&2; exit 1; \
	else \
		echo 'iOS: xcodebuild available'; \
	fi

ios-generate:
	@if [ "$$(uname -s)" != "Darwin" ]; then \
		echo 'ios-generate requires macOS' >&2; exit 1; \
	fi
	@command -v xcodegen >/dev/null 2>&1 || { \
		echo 'xcodegen not found; install it first' >&2; exit 1; \
	}
	cd $(IOS_DIR) && xcodegen generate

ios-list:
	@if [ "$$(uname -s)" != "Darwin" ]; then \
		echo 'ios-list requires macOS' >&2; exit 1; \
	fi
	xcodebuild -list -project "$(IOS_PROJECT)"

ios-build: ios-build-damage ios-build-ecai

ios-build-damage:
	@if [ "$$(uname -s)" != "Darwin" ]; then \
		echo 'iOS builds require macOS/Xcode' >&2; exit 1; \
	fi
	xcodebuild \
		-project "$(IOS_PROJECT)" \
		-scheme DamageBDD \
		-configuration "$(IOS_CONFIGURATION)" \
		-destination "$(IOS_DESTINATION)" \
		-derivedDataPath "$(IOS_DERIVED_DATA)/DamageBDD" \
		build

ios-build-ecai:
	@if [ "$$(uname -s)" != "Darwin" ]; then \
		echo 'iOS builds require macOS/Xcode' >&2; exit 1; \
	fi
	xcodebuild \
		-project "$(IOS_PROJECT)" \
		-scheme ECAI \
		-configuration "$(IOS_CONFIGURATION)" \
		-destination "$(IOS_DESTINATION)" \
		-derivedDataPath "$(IOS_DERIVED_DATA)/ECAI" \
		build

ios-clean:
	@rm -rf "$(IOS_DERIVED_DATA)"
