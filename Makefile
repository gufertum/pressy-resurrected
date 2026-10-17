# With only the Command Line Tools installed, swift test does not find the swift-testing macro plugin.
TESTING_PLUGINS := /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
TEST_FLAGS := $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS))

.PHONY: build test cert install uninstall reload logs

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
