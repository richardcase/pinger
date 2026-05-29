BINARY := pinger

.PHONY: all build test itest lint fmt fmt-fix clean release-local

all: build

build:
	zig build -Doptimize=ReleaseFast

test:
	zig build test

# Integration tests open raw ICMP sockets, so they need root/CAP_NET_RAW and
# are run as a standalone binary (the `zig build` test runner can't host them).
itest:
	zig build itest -Dintegration
	sudo ./zig-out/bin/pinger-itest

lint: fmt

fmt:
	zig fmt --check build.zig src

fmt-fix:
	zig fmt build.zig src

clean:
	rm -rf zig-out .zig-cache $(BINARY)

# Build the full cross-compile matrix locally (linux/macos x amd64/arm64).
release-local:
	for t in x86_64-linux-musl aarch64-linux-musl x86_64-macos aarch64-macos; do \
		zig build -Dtarget=$$t -Doptimize=ReleaseFast; \
	done
