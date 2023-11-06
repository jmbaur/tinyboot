#!/usr/bin/env nix-shell
#!nix-shell -i bash -p openssl vboot_reference
# shellcheck shell=bash
script_dir="$(dirname "$0")"
out="${1:-$script_dir}"

function make_vboot_pair() {
	pair_out="${out}/$1"
	mkdir -p "${pair_out}"

	# make the RSA keypair
	openssl genrsa -F4 -out "${pair_out}/key.pem" "$2"

	# create a self-signed certificate
	openssl req -batch -new -x509 -key "${pair_out}/key.pem" -out "${pair_out}/key.crt"

	# generate pre-processed RSA public key
	dumpRSAPublicKey -cert "${pair_out}/key.crt" >"${pair_out}/key.keyb"

	# Algorithm ID mappings:
	# RSA1024_SHA1_ALGOID=0
	# RSA1024_SHA256_ALGOID=1
	# RSA1024_SHA512_ALGOID=2
	# RSA2048_SHA1_ALGOID=3
	# RSA2048_SHA256_ALGOID=4
	# RSA2048_SHA512_ALGOID=5
	# RSA4096_SHA1_ALGOID=6
	RSA4096_SHA256_ALGOID=7
	# RSA4096_SHA512_ALGOID=8
	# RSA8192_SHA1_ALGOID=9
	RSA8192_SHA256_ALGOID=10
	# RSA8192_SHA512_ALGOID=11

	case "$2" in
	"8192")
		alg=$RSA8192_SHA256_ALGOID
		;;
	*)
		alg=$RSA4096_SHA256_ALGOID
		;;
	esac

	# wrap the public key
	vbutil_key \
		--pack "${pair_out}/key.vbpubk" \
		--key "${pair_out}/key.keyb" \
		--version "1" \
		--algorithm "$alg"

	# wrap the private key
	vbutil_key \
		--pack "${pair_out}/key.vbprivk" \
		--key "${pair_out}/key.pem" \
		--algorithm "$alg"

	# remove intermediate files
	rm "${pair_out}/key.keyb"

	signer=${3:-$1}

	# keyblock flags:
	#   0x01  Developer switch off
	#   0x02  Developer switch on
	#   0x04  Not recovery mode
	#   0x08  Recovery mode
	#   0x10  Not miniOS mode
	#   0x20  miniOS mode

	# create keyblock
	vbutil_keyblock \
		--pack "${pair_out}/key.keyblock" \
		--flags 5 \
		--datapubkey "${pair_out}/key.vbpubk" \
		--signprivate "${out}/${signer}/key.vbprivk"

	# verify keyblock
	vbutil_keyblock \
		--unpack "${pair_out}/key.keyblock" \
		--signpubkey "${out}/${signer}/key.vbpubk"
}

function make_tboot_pair() {
	pair_out="${out}/$1"
	mkdir -p "${pair_out}"

	# make the RSA keypair
	openssl genrsa -F4 -out "${pair_out}/key.pem" "$2"

	# create a certificate signed by CA
	openssl req -batch -new -x509 -key "${pair_out}/key.pem" -CA "${out}/${3}/key.crt" -CAkey "${out}/${3}/key.pem" -out "${pair_out}/key.crt"

	# export the public key certificate in DER format
	openssl x509 -inform PEM -in "${pair_out}/key.crt" -outform DER -out "${pair_out}/key.der"
}

make_vboot_pair root 8192
make_vboot_pair firmware 4096 root
make_tboot_pair tboot 4096 root
