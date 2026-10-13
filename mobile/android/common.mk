SHELL := /bin/bash

NODE ?= node
NPM ?= npm
NPX ?= npx
ADB ?= adb
PYTHON ?= python
DEVICE_SERIAL ?=
ADB_TARGET = $(if $(strip $(DEVICE_SERIAL)),-s $(DEVICE_SERIAL),)
APK := android/app/build/outputs/apk/debug/app-debug.apk
AAB := android/app/build/outputs/bundle/release/app-release.aab

.PHONY: doctor deps web init sync build release install launch run log preview \
        print-apk clean distclean

doctor:
	@../scripts/doctor.sh

deps:
	$(NPM) install

web:
	$(NPM) run web

init: deps web
	@if [ ! -d android ]; then $(NPX) cap add android; fi
	$(NPX) cap sync android

sync: web
	@if [ ! -d node_modules/@capacitor/core ]; then \
		echo "Missing node_modules; run 'make deps' or 'make init'." >&2; exit 1; \
	fi
	@if [ ! -d android ]; then \
		echo "Missing android/; run 'make init'." >&2; exit 1; \
	fi
	$(NPX) cap sync android

build: sync
	cd android && ./gradlew assembleDebug

release: sync
	cd android && ./gradlew bundleRelease

install: build
	$(ADB) $(ADB_TARGET) install -r "$(APK)"

launch:
	$(ADB) $(ADB_TARGET) shell monkey \
		-p "$(APP_ID)" \
		-c android.intent.category.LAUNCHER 1 >/dev/null

run: install launch

log:
	$(ADB) $(ADB_TARGET) logcat | \
		grep --line-buffered -iE '$(APP_NAME)|capacitor|chromium|AndroidRuntime'

preview: web
	$(PYTHON) -m http.server 4173 --directory www

print-apk:
	@printf '%s\n' "$(CURDIR)/$(APK)"

clean:
	@rm -rf www
	@if [ -x android/gradlew ]; then cd android && ./gradlew clean; fi

distclean: clean
	@rm -rf node_modules
