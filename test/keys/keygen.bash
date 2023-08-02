#!/usr/bin/env bash

out="${1:-$(dirname "$0")}"

GENKEY="${out}/x509_ima.genkey"

cat <<EOF >"$GENKEY"
[ req ]
default_bits = 4096
distinguished_name = req_distinguished_name
prompt = no
string_mask = utf8only
x509_extensions = myexts

[ req_distinguished_name ]
O = tinyhost
CN = tinyboot test signing key
emailAddress = tboot@tinyhost

[ myexts ]
basicConstraints=critical,CA:FALSE
keyUsage=digitalSignature
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid
EOF

openssl req -x509 -new -nodes -utf8 -sha1 -days 3650 -batch -config "$GENKEY" \
	-outform DER -out "${out}/x509_ima.der" -keyout "${out}/privkey_ima.pem"

openssl x509 -inform DER -in "${out}/x509_ima.der" -out "${out}/x509_ima.pem"

openssl rsa -pubout -in "${out}/privkey_ima.pem" -out "${out}/pubkey_ima.pem"
