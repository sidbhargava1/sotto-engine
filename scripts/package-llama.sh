#!/usr/bin/env bash
# Zips Vendor/llama.xcframework into the release asset remote consumers of the engine resolve
# (open-core ADR §6, H1) and writes the release tag and checksum into the engine's Package.swift.
# Upload exactly build/llama.xcframework.zip to that release: the checksum in the tagged commit
# must match it byte for byte. Works in this repo (Packages/SottoEngine) and in the published engine.
set -euo pipefail
cd "$(dirname "$0")/.."

RELEASE=${1:?usage: scripts/package-llama.sh <engine release tag, e.g. 0.1.0>}
MANIFEST=Package.swift
[ -f Packages/SottoEngine/Package.swift ] && MANIFEST=Packages/SottoEngine/Package.swift
FW=Vendor/llama.xcframework
OUT=build/llama.xcframework.zip

[ -d "$FW" ] || { echo "$FW missing: run scripts/build-llama.sh" >&2; exit 1; }
# The stamp release.sh checks: never package a framework built from another llama.cpp commit.
WANT="$(sed -n 's/^LLAMA_COMMIT=\([0-9a-f]*\).*/\1/p' scripts/build-llama.sh)"
HAVE="$(cat "$FW.commit" 2>/dev/null || true)"
[ "$HAVE" = "$WANT" ] || { echo "$FW is from '${HAVE:-unknown}', want $WANT: run scripts/build-llama.sh" >&2; exit 1; }

# Reproducible: fixed mtimes, no xattrs/ACLs/resource forks, so the same framework always hashes the same.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$FW" "$STAGE/"
# MIT requires the notice to travel with the binary.
cp Vendor/llama.cpp-src/LICENSE "$STAGE/llama.xcframework/LICENSE.llama.cpp" || { echo "llama.cpp LICENSE missing" >&2; exit 1; }
find "$STAGE/llama.xcframework" -exec touch -h -t 200001010000 {} +
mkdir -p build
rm -f "$OUT"
ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "$STAGE/llama.xcframework" "$OUT"

SUM="$(cd "$(dirname "$MANIFEST")" && swift package compute-checksum "$OLDPWD/$OUT")"
[ "$SUM" = "$(shasum -a 256 "$OUT" | cut -d' ' -f1)" ] || { echo "checksum mismatch" >&2; exit 1; }

sed -i '' \
    -e "s/^let llamaRelease = .*/let llamaRelease = \"$RELEASE\"/" \
    -e "s/^let llamaChecksum = .*/let llamaChecksum = \"$SUM\"  \/\/ llama.cpp $WANT/" \
    "$MANIFEST"
grep -q "^let llamaChecksum = \"$SUM\"" "$MANIFEST" || { echo "couldn't write $MANIFEST" >&2; exit 1; }

echo "Packaged $OUT (llama.cpp $WANT)"
echo "checksum $SUM"
echo "url      https://github.com/sidbhargava1/sotto-engine/releases/download/$RELEASE/llama.xcframework.zip"
echo "Wrote both into $MANIFEST; commit it before tagging $RELEASE."
