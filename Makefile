.PHONY: check lint run run-headless syntax test shell-test mpv-integration \
	kinamp-integration smoke-integration remote-integration simulator-test release-test dist

LUA_FILES := $(shell find koreadalong.koplugin spec -type f -name '*.lua' 2>/dev/null)
BUSTED ?= /usr/bin/busted

check: lint syntax test shell-test simulator-test release-test

lint:
	luacheck -q koreadalong.koplugin spec

syntax:
	@for file in $(LUA_FILES); do luajit -b "$$file" /dev/null; done

test:
	luajit $(BUSTED) --verbose spec

shell-test:
	@for file in scripts/kinamp-diagnostic spec/kinamp_diagnostic_test.sh; do sh -n "$$file"; done
	./spec/kinamp_diagnostic_test.sh

simulator-test:
	python3 spec/storyteller_simulator_test.py

release-test:
	python3 spec/release_test.py

dist:
	python3 scripts/package-release "$(VERSION)"

mpv-integration:
	KOREADER_MPV_INTEGRATION=1 LUA_PATH='./koreadalong.koplugin/?.lua;.cache/koreader/lib/koreader/?.lua;.cache/koreader/lib/koreader/common/?.lua;/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;;' LUA_CPATH='./.cache/koreader/lib/koreader/common/?.so;/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;' .cache/koreader/lib/koreader/luajit $(BUSTED) --verbose spec/mpv_integration_spec.lua

kinamp-integration:
	LUA_PATH='./koreadalong.koplugin/?.lua;.cache/koreader/lib/koreader/?.lua;.cache/koreader/lib/koreader/common/?.lua;/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;;' LUA_CPATH='./.cache/koreader/lib/koreader/common/?.so;./.cache/koreader/lib/koreader/?.so;/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;' .cache/koreader/lib/koreader/luajit $(BUSTED) --verbose spec/kinamp_integration_spec.lua

smoke-integration:
	./scripts/run-smoke

remote-integration:
	./scripts/run-remote-smoke

run:
	./scripts/run-koreader

run-headless:
	@status=0; timeout 5s xvfb-run -a ./scripts/run-koreader || status=$$?; \
		test "$$status" -eq 0 -o "$$status" -eq 124
