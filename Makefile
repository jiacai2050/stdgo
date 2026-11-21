.PHONY: all build test run-examples fmt fmt-check ci

all: ci

build:
	zig build

test:
	zig build test -Dsqlite=true -Dtsan=true --summary all

run-examples:
	zig build run-examples
	zig build run-sql -Dsqlite=true

fmt:
	zig fmt src examples build.zig

fmt-check:
	zig fmt --check src examples build.zig

ci: fmt-check build test run-examples
