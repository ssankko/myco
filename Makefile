DIST := dist
HAL := /Library/Audio/Plug-Ins/HAL

.PHONY: build install uninstall run test test-capture

build:
	./scripts/bundle.sh

install: build
	osascript -e 'do shell script "rm -rf $(HAL)/Myco.driver && cp -R \"$(CURDIR)/$(DIST)/Myco.driver\" $(HAL)/ && killall coreaudiod" with administrator privileges'

uninstall:
	osascript -e 'do shell script "rm -rf $(HAL)/Myco.driver && killall coreaudiod" with administrator privileges'

run: build
	open $(DIST)/Myco.app

test:
	swift test

# Tests that capture audio need the microphone permission Terminal.app holds.
test-capture:
	./scripts/terminal-run.sh /tmp/myco-test.txt swift test
