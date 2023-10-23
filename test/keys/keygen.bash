#!/usr/bin/env nix-shell
#!nix-shell -i bash -p openssl
# shellcheck shell=bash
script_dir="$(dirname "$0")"
out="${1:-$script_dir}"
openssl req -x509 -new -nodes -utf8 -sha1 -days 3650 -batch -config "${script_dir}/openssl.cnf" -outform DER -out "${out}/x509_ima.der" -keyout "${out}/privkey_ima.pem"
openssl x509 -inform DER -in "${out}/x509_ima.der" -out "${out}/x509_ima.pem"
openssl rsa -pubout -in "${out}/privkey_ima.pem" -out "${out}/pubkey_ima.pem"
