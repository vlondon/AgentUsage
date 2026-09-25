#!/bin/zsh
set -euo pipefail

# Creates a self-signed code signing certificate in your login keychain, so that
# package_app.sh signs every build with the same identity and macOS remembers
# "Always Allow" for the app's Keychain items across rebuilds.
# Not needed if an Apple Development certificate is already installed.
# Nothing is sent anywhere; delete the certificate in Keychain Access to undo.

NAME="Agent Allowance Local Signing"
KEYCHAIN=${KEYCHAIN:-"$HOME/Library/Keychains/login.keychain-db"}
OPENSSL=/usr/bin/openssl

if security find-identity -p codesigning "$KEYCHAIN" | grep -qF "\"$NAME\""; then
    echo "\"$NAME\" already exists in $KEYCHAIN"
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
umask 077

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no

[dn]
CN = $NAME

[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2> /dev/null

PASSWORD=$("$OPENSSL" rand -hex 16)
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/identity.p12" \
    -passout "pass:$PASSWORD" -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1

# -T lets codesign use the private key; other apps still have to ask.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign > /dev/null

echo "Created \"$NAME\" in $KEYCHAIN."
echo "scripts/package_app.sh will now sign with it. If macOS asks whether codesign may use the key, choose Always Allow."
