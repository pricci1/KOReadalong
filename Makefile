.PHONY: check lint run run-headless syntax test mpv-integration smoke-integration

LUA_FILES := $(shell find koreadalong.koplugin spec -type f -name '*.lua' 2>/dev/null)

check: lint syntax test

lint:
	luacheck -q koreadalong.koplugin spec

syntax:
	@for file in $(LUA_FILES); do luajit -b "$$file" /dev/null; done

test:
	luajit /usr/bin/busted --verbose spec

mpv-integration:
	KOREADER_MPV_INTEGRATION=1 LUA_PATH='./koreadalong.koplugin/?.lua;.cache/koreader/lib/koreader/?.lua;.cache/koreader/lib/koreader/common/?.lua;/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;;' LUA_CPATH='./.cache/koreader/lib/koreader/common/?.so;/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;' .cache/koreader/lib/koreader/luajit /usr/bin/busted --verbose spec/mpv_integration_spec.lua

smoke-integration:
	./scripts/run-smoke

run:
	./scripts/run-koreader

run-headless:
	@status=0; timeout 5s xvfb-run -a ./scripts/run-koreader || status=$$?; \
		test "$$status" -eq 0 -o "$$status" -eq 124
