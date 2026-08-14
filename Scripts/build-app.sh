#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-debug}"
APP_PATH="$ROOT_DIR/LimitIsland.app"

# A stable identity matters more than it looks: the keychain remembers "Always
# Allow" per code signature, so re-signing ad-hoc on every build would make macOS
# re-prompt for the Gemini CLI credential every single time. Create one once with
# Keychain Access -> Certificate Assistant -> Create a Certificate, named
# "LimitIsland Local", type "Code Signing", self-signed.
IDENTITY="${CODESIGN_IDENTITY:-LimitIsland Local}"
if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
	if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
		echo "error: CODESIGN_IDENTITY '$IDENTITY' not found." >&2
		exit 1
	fi
	echo "Creating self-signed code signing certificate '$IDENTITY'…"
	"$(dirname "$0")/create-signing-identity.sh" "$IDENTITY" || true
	if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
		echo "warning: could not create '$IDENTITY'; falling back to ad-hoc."
		echo "         macOS will re-ask for keychain access after every build. See README.md."
		IDENTITY="-"
	fi
fi

cd "$ROOT_DIR"
swift build --configuration "$CONFIGURATION" --product LimitIsland
swift build --configuration "$CONFIGURATION" --product limitisland-hook

BIN_DIR="$(swift build --configuration "$CONFIGURATION" --show-bin-path)"
BIN_PATH="$BIN_DIR/LimitIsland"

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$APP_PATH/Contents/Helpers"
cp "$BIN_PATH" "$APP_PATH/Contents/MacOS/LimitIsland"
# The CLIs invoke this by absolute path, recorded in their settings when the user
# installs the hooks. Moving the app therefore invalidates the install, which
# HookInstaller.state() reports as `stale` rather than failing silently.
cp "$BIN_DIR/limitisland-hook" "$APP_PATH/Contents/Helpers/limitisland-hook"
cp "$ROOT_DIR/Scripts/Info.plist" "$APP_PATH/Contents/Info.plist"

# Optional: run the Google sign-in as your own OAuth client instead of the public
# one the Gemini CLI ships. The keys go into the *copy* only, so a private client
# never reaches the tracked plist and cannot be committed. Unset is the normal
# case — the app falls back to the bundled public client.
plist_set() {
	/usr/libexec/PlistBuddy -c "Add :$1 string $2" "$APP_PATH/Contents/Info.plist" >/dev/null 2>&1 || \
		/usr/libexec/PlistBuddy -c "Set :$1 $2" "$APP_PATH/Contents/Info.plist" >/dev/null
}
if [[ -n "${GOOGLE_OAUTH_CLIENT_ID:-}" ]]; then
	plist_set GoogleOAuthClientID "$GOOGLE_OAUTH_CLIENT_ID"
fi
if [[ -n "${GOOGLE_OAUTH_CLIENT_SECRET:-}" ]]; then
	plist_set GoogleOAuthClientSecret "$GOOGLE_OAUTH_CLIENT_SECRET"
fi

# Keep SwiftPM's processed resource bundle with the packaged executable. Replace
# rather than merge — copying into an existing bundle never prunes, which is how
# a resource deleted from the source tree stayed in the shipped app for months.
for resource_bundle in "$BIN_DIR"/*.bundle(N); do
	rm -rf "$APP_PATH/Contents/Resources/${resource_bundle:t}"
	cp -R "$resource_bundle" "$APP_PATH/Contents/Resources/"
done

# Copying out of .build brings extended attributes along, and codesign refuses to
# sign a bundle carrying `com.apple.FinderInfo` ("resource fork, Finder
# information, or similar detritus not allowed").
#
# Clearing once is not enough. When the checkout lives in a file-provider-synced
# folder — iCloud Drive, Dropbox, Google Drive over ~/Documents — the sync daemon
# re-adds the attribute at any moment, including between the clear and the signature.
# So this retries rather than races: clear, sign, and if the attribute came back in
# that window, go round again.
sign() {
	local target="$1" attempt
	for attempt in 1 2 3; do
		xattr -cr "$target"
		if codesign --force --sign "$IDENTITY" "$target" 2>/dev/null; then
			return 0
		fi
		sleep 0.3
	done
	echo "error: could not sign $target" >&2
	codesign --force --sign "$IDENTITY" "$target"   # run once more for the message
	return 1
}

# Nested executables are signed first: signing the bundle seals their signatures
# into its own, so an unsigned helper would invalidate the app the moment it ran.
sign "$APP_PATH/Contents/Helpers/limitisland-hook"
sign "$APP_PATH"
echo "Built $APP_PATH (signed with $IDENTITY)"
