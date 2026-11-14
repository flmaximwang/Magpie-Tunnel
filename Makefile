# Magpie-Tunnel developer tasks
.PHONY: build test build-apps install-apps clean

build:
	swift build

test:
	swift test

build-apps:
	./scripts/build-apps.sh

install-apps:
	./scripts/install-apps.sh

clean:
	swift package clean
	rm -rf .build dist
