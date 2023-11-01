# shellcheck shell=bash

# TODO(jared): detect which slot to write to
flashrom --programmer internal --noverify-all --fmap --include RW_SECTION_A --write NEW_ROM
