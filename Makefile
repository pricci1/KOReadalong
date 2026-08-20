.PHONY: check lint run run-headless syntax test

LUA_FILES := $(shell find koreadalong.koplugin spec -type f -name '*.lua' 2>/dev/null)

check: lint syntax test

lint:
	luacheck -q koreadalong.koplugin spec

syntax:
	@for file in $(LUA_FILES); do luajit -b "$$file" /dev/null; done

test:
	luajit /usr/bin/busted --verbose spec

run:
	./scripts/run-koreader

run-headless:
	@status=0; timeout 5s xvfb-run -a ./scripts/run-koreader || status=$$?; \
		test "$$status" -eq 0 -o "$$status" -eq 124
