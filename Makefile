.PHONY: all build test clean run run-cli macos ios xcframework xcframework-ios

all: build

build:
	zig build

test:
	zig build test

run:
	zig build run

run-cli:
	zig build run-cli

macos:
	zig build macos

ios:
	zig build ios

xcframework:
	zig build xcframework

xcframework-ios:
	zig build xcframework-ios

clean:
	rm -rf \
		zig-out \
		.zig-cache \
		macos/build \
		macos/BobrWhisperKit.xcframework \
		ios/BobrWhisperKit.xcframework \
		~/Library/Developer/Xcode/DerivedData/BobrWhisper-*
