#!/bin/zsh

# Creates a self-signed code-signing certificate in the login keychain.
#
# Why this exists: the keychain remembers "Always Allow" per code signature. Ad-hoc
# signing (`codesign -s -`) produces a new identity on every build, so every rebuild
# would invalidate the decision and macOS would ask for provider credentials again.
# One stable local identity turns that into a single prompt for the life of the
# machine.
#
# This is the same certificate Keychain Access -> Certificate Assistant would make,
# without the eight-dialog walkthrough. It grants nothing beyond signing locally
# built binaries: it is not trusted by anyone else, and Gatekeeper still treats the
# app as unsigned by a developer.

set -euo pipefail

NAME="${1:-LimitIsland Local}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# `extendedKeyUsage = codeSigning` is the part that matters — without it the
# certificate exists but `security find-identity -p codesigning` will not list it.
cat > "$WORK_DIR/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no

[ dn ]
CN = $NAME

[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
	-keyout "$WORK_DIR/key.pem" -out "$WORK_DIR/cert.pem" \
	-days 3650 -config "$WORK_DIR/openssl.cnf" >/dev/null 2>&1

# The legacy PBE algorithms are not a preference: macOS's Security framework
# cannot read a PKCS#12 written with OpenSSL 3's modern defaults, and reports it
# as "MAC verification failed (wrong password?)" — which sends you looking for a
# password problem that does not exist.
PASSPHRASE="limitisland-local"
openssl pkcs12 -export -inkey "$WORK_DIR/key.pem" -in "$WORK_DIR/cert.pem" \
	-out "$WORK_DIR/identity.p12" -passout "pass:$PASSPHRASE" \
	-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1

LOGIN_KEYCHAIN="$(security default-keychain | tr -d ' "')"

# `-T /usr/bin/codesign` pre-authorises codesign against the private key, so the
# build does not stop on a keychain dialog of its own.
security import "$WORK_DIR/identity.p12" \
	-k "$LOGIN_KEYCHAIN" -P "$PASSPHRASE" -T /usr/bin/codesign -A >/dev/null

# Trust it for code signing so `find-identity -v` reports it as valid.
security add-trusted-cert -d -r trustRoot -p codeSign \
	-k "$LOGIN_KEYCHAIN" "$WORK_DIR/cert.pem" >/dev/null 2>&1 || \
	echo "note: could not mark '$NAME' as trusted (this usually needs an admin prompt);" \
	     "signing may still work, otherwise trust it manually in Keychain Access."

echo "Created code signing identity '$NAME'."
