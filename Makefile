# With only the Command Line Tools installed, swift test does not find the swift-testing macro plugin.
TESTING_PLUGINS := /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
TEST_FLAGS := $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS))

.PHONY: build test cert install uninstall reload logs release screenshots

build:
	swift build -c release

test:
	swift test $(TEST_FLAGS)

cert:
	scripts/make-signing-cert.sh

install: test
	scripts/install.sh

uninstall:
	scripts/uninstall.sh

reload:
	pressy reload

logs:
	tail -f ~/Library/Logs/pressy.log

release: test
	scripts/release.sh

# The app renders its own windows with demo data, so no Screen Recording permission is needed.
screenshots:
	swift build -c release
	.build/release/PressyBar --screenshots $(CURDIR)/docs/images
