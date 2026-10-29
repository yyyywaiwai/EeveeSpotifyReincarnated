#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
OUTPUT="$(mktemp "${TMPDIR:-/tmp}/eevee-playplay-test.XXXXXX")"
trap 'rm -f "$OUTPUT"' EXIT
cc -std=c11 -Wall -Wextra -Werror -o "$OUTPUT" "$ROOT/Tests/OfflinePlayPlay/test.c"
"$OUTPUT"
