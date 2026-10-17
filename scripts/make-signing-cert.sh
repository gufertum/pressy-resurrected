#!/usr/bin/env bash
# Creates the self-signed code-signing identity "pressy local signing" in the login keychain, once.
# install.sh signs every build with it, so the macOS privacy grants (Input Monitoring, Automation)
# survive rebuilds. Ad-hoc signatures change with every build and lose them.
# The certificate is not added to any trust settings; only /usr/bin/codesign may use the key.
set -euo pipefail

NAME="${PRESSY_SIGN_IDENTITY:-pressy local signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL=/usr/bin/openssl # LibreSSL: writes a .p12 that `security import` can read

if security find-identity -p codesigning "$KEYCHAIN" | grep -qF "\"$NAME\""; then
  echo "code-signing identity \"$NAME\" already exists, nothing to do"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# Protects only the temporary .p12 between export and import; it is deleted on exit.
PASS="$("$OPENSSL" rand -hex 16)"

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem"
"$OPENSSL" pkcs12 -export -name "$NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout "pass:$PASS"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign

security find-identity -p codesigning "$KEYCHAIN" | grep -F "\"$NAME\""
echo "created \"$NAME\" in the login keychain (self-signed, valid 10 years)"
echo "next: make install"
