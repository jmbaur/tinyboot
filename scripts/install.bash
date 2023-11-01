# shellcheck shell=bash

flashrom --programmer internal --wp-disable
vpd -f OLD_ROM -l | grep VPD_INHERIT_FROM_OLD_GREP_FLAGS | xargs -n1 vpd -f NEW_ROM -s
flashrom --programmer internal --wp-range 0 0
flashrom --programmer internal --write NEW_ROM EXTRA_FLAGS
flashrom --programmer internal --wp-range START LENGTH --wp-enable
