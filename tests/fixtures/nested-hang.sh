#!/usr/bin/env bash
set -uo pipefail
: "${MAESTRO_TEST_NESTED_PID_FILE:?missing nested pid file}"
set -m
sleep 60 &
child=$!
printf '%s\n' "$child" > "$MAESTRO_TEST_NESTED_PID_FILE"
wait "$child"
