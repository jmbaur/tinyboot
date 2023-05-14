# shellcheck shell=bash
pushd "$(dirname "$0")" || exit
openssl genpkey -algorithm ed25519 -out privkey
openssl pkey -in privkey -pubout -out pubkey
popd || exit
