#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(mktemp "${TMPDIR:-/tmp}/ppkc-test.XXXXXX")
trap 'rm -f "$output"' EXIT HUP INT TERM
cc -std=c11 -Wall -Wextra -Werror -pthread \
  "$root/Tests/OfflinePlayPlayKeyCapture/test.c" -o "$output"
"$output"
cc -std=c11 -Wall -Wextra -Werror -pthread -DTEST_CALLBACK_ATTACH_FAILURE \
  "$root/Tests/OfflinePlayPlayKeyCapture/test.c" -o "$output"
"$output"
cc -std=c11 -Wall -Wextra -Werror -pthread -DTEST_PREFETCH_ATTACH_FAILURE \
  "$root/Tests/OfflinePlayPlayKeyCapture/test.c" -o "$output"
"$output"
cc -std=c11 -Wall -Wextra -Werror -pthread -DTEST_PREFETCH_SIGNATURE_FAILURE \
  "$root/Tests/OfflinePlayPlayKeyCapture/test.c" -o "$output"
"$output"
cc -std=c11 -Wall -Wextra -Werror -pthread \
  "$root/Tests/OfflinePlayPlayKeyCapture/test-gum.c" -o "$output"
"$output"
cc -std=c11 -Wall -Wextra -Werror -pthread -DTEST_ATTACH_FAILURE \
  "$root/Tests/OfflinePlayPlayKeyCapture/test-gum.c" -o "$output"
"$output"
cc -std=c11 -Wall -Wextra -Werror -pthread -DTEST_KEY_GRAFT_MISMATCH \
  "$root/Tests/OfflinePlayPlayKeyCapture/test-gum.c" -o "$output"
"$output"
cc -std=c11 -Wall -Wextra -Werror -pthread -DTEST_PREFETCH_ATTACH_FAILURE \
  "$root/Tests/OfflinePlayPlayKeyCapture/test-gum.c" -o "$output"
"$output"
cc -std=c11 -Wall -Wextra -Werror -pthread -DTEST_PREFETCH_GRAFT_MISMATCH \
  "$root/Tests/OfflinePlayPlayKeyCapture/test-gum.c" -o "$output"
"$output"
