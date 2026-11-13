#!/bin/bash
# Runs INSIDE pool 1's container. Phase 1: REVOKE a gateway (removes its key hash from the registry list).
#   P0_DIR=/tmp/p0n ./p1-revoke.sh <magic> A|B
# Same as p1-enroll.sh, other direction; idempotent (not on the list: says so and changes nothing).
export P1_ACTION=remove
exec bash "$(dirname "$0")/p1-enroll.sh" "$@"
