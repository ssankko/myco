DIST := dist
HAL := /Library/Audio/Plug-Ins/HAL

.PHONY: build install uninstall run test test-capture

build:
	./scripts/bundle.sh

install: build
	osascript -e 'do shell script "rm -rf $(HAL)/Mixanimo.driver && cp -R \"$(CURDIR)/$(DIST)/Mixanimo.driver\" $(HAL)/ && killall coreaudiod" with administrator privileges'

uninstall:
	osascript -e 'do shell script "rm -rf $(HAL)/Mixanimo.driver && killall coreaudiod" with administrator privileges'

run: build
	open $(DIST)/Mixanimo.app

test:
	swift test

# Tests that capture audio need the microphone permission Terminal.app holds.
test-capture:
	./scripts/terminal-run.sh /tmp/mixanimo-test.txt swift test
