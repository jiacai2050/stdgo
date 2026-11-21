.PHONY: all build test test-tsan run-examples fmt fmt-check ci

all: ci

build:
	zig build

test:
	zig build test --summary all
	zig build test -Dsqlite=true --summary all

test-tsan:
	zig build test -Dtsan=true --summary all
	zig build test -Dsqlite=true -Dtsan=true --summary all

run-examples:
	zig build run-examples
	zig build run-sql -Dsqlite=true

fmt:
	zig fmt src examples build.zig

fmt-check:
	zig fmt --check src examples build.zig

ci: fmt-check build test test-tsan run-examples
