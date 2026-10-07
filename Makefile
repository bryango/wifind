# wifind - macOS Wi-Fi scanner and connector with a terminal UI
#
# SANDBOX_FLAG: SwiftPM sandboxes manifest compilation with sandbox-exec, which
# cannot nest inside another sandbox (agent sandboxes, some CI runners). Pass
# SANDBOX_FLAG= from a normal shell to let SwiftPM sandbox itself.
SANDBOX_FLAG ?= --disable-sandbox
SWIFT ?= swift
SWIFT_ENV ?= CLANG_MODULE_CACHE_PATH=$(CURDIR)/.build/modulecache SWIFTPM_MODULECACHE_OVERRIDE=$(CURDIR)/.build/modulecache
BIN := .build/release/wifind
APP := Wifind.app

.PHONY: all build test app run doctor scan clean

all: build

build:
	$(SWIFT_ENV) $(SWIFT) build -c release $(SANDBOX_FLAG)

test:
	$(SWIFT_ENV) $(SWIFT) test $(SANDBOX_FLAG)

# Wraps the binary in an app bundle so macOS attributes Location Services to
# wifind instead of to the terminal. Ad-hoc signed; rebuilding invalidates a
# previously granted permission because the code hash changes.
app: build
	scripts/make-app.sh

run: build
	$(BIN)

doctor: build
	$(BIN) doctor

scan: build
	$(BIN) scan

clean:
	$(SWIFT_ENV) $(SWIFT) package clean $(SANDBOX_FLAG) || true
	rm -rf $(APP)
