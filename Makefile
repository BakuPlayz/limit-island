.PHONY: app run test clean

app:
	Scripts/build-app.sh

run:
	Scripts/build-app.sh
	open LimitIsland.app

# The Command Line Tools toolchain ships no XCTest or swift-testing, so fall
# back to Xcode's when `xcode-select` points at CLT.
test:
	@if [ -d "$$(xcode-select -p)/Library/Frameworks/XCTest.framework" ]; then \
		swift test; \
	elif [ -d /Applications/Xcode.app ]; then \
		echo "note: using Xcode's toolchain; CLT has no test frameworks."; \
		DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test; \
	else \
		echo "error: no toolchain with test frameworks. Install Xcode, or run 'sudo xcode-select -s /Applications/Xcode.app'." >&2; \
		exit 1; \
	fi

# Also clears .build: a stale resource bundle there can mask a file that is
# missing from the source tree entirely.
clean:
	rm -rf LimitIsland.app .build
