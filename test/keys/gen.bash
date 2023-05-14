# shellcheck shell=bash
out=${1:-"$(dirname "$0")"}
openssl genpkey -algorithm ed25519 -out "${out}/privkey"
openssl pkey -in "${out}/privkey" -pubout -out "${out}/pubkey"
