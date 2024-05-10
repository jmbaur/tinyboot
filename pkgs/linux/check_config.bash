# shellcheck shell=bash

set -o errexit
set -o nounset
set -o pipefail

start_config=$1
end_config=$2

missing=()
while read -r line; do
	if ! grep --silent "$line" "$end_config"; then
		missing+=("$line")
	fi
done <"$start_config"

if [[ ${#missing[@]} -gt 0 ]]; then
	echo
	for line in "${missing[@]}"; do
		echo "\"$line\" not found in final config!"
	done
	echo
	exit 1
fi
