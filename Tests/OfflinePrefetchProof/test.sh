#!/bin/sh
set -eu

cd "$(dirname "$0")/../.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

source=Sources/EeveeSpotify/Offline/OfflinePrefetchProof.swift
swiftc -D EEVEE_OFFLINE_PREFETCH_PROOF Tests/OfflinePrefetchProof/main.swift "$source" -o "$tmp/proof-test"
nm -gU "$tmp/proof-test" | grep -q ' _eevee_offline_prefetch_proof_once$'
for scenario in wrong-version wrong-thread wrong-track already-saved invalid-store success no-key other-failure wrong-saved-uri; do
    "$tmp/proof-test" "$scenario"
done

swiftc -emit-library "$source" -o "$tmp/libnormal.dylib"
if nm -gU "$tmp/libnormal.dylib" 2>/dev/null | grep -q 'eevee_offline_prefetch_proof_once'; then
    echo 'normal build exported the proof entrypoint' >&2
    exit 1
fi
echo 'OfflinePrefetchProof symbol gating passed'
node --check Scripts/offline-prefetch-proof.js
node Tests/OfflinePrefetchProof/runner.test.js
/Users/yyyywaiwai/.local/share/uv/tools/frida-tools/bin/python Tests/OfflinePrefetchProof/python_runner.test.py
