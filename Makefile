DIST := dist
HAL := /Library/Audio/Plug-Ins/HAL

.PHONY: build install uninstall run test

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
