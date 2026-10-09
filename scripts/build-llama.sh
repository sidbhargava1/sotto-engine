#!/usr/bin/env bash
# Builds Vendor/llama.xcframework from a pinned llama.cpp commit with upstream's own
# build-xcframework.sh (macOS slice only). Upstream ships no Package.swift, so SwiftPM links this
# as a binaryTarget. Run once per checkout, and again after bumping LLAMA_COMMIT; then
# scripts/package-llama.sh makes the release asset URL consumers resolve. Published with the engine
# (open-core ADR §6); in the Sotto app repo, Packages/SottoEngine/Vendor is a symlink to this Vendor/.
set -euo pipefail
cd "$(dirname "$0")/.."

LLAMA_TAG=b11514
LLAMA_COMMIT=de7fa0a3c6a2e1b4cd9f22eb8d6bf5b12dbdb63b  # was v0.5.0 7fe450e (b11146)
SRC=Vendor/llama.cpp-src
OUT=Vendor/llama.xcframework

command -v cmake >/dev/null || { echo "cmake not found (brew install cmake)" >&2; exit 1; }

if [ ! -d "$SRC/.git" ]; then
    git clone --depth 1 --branch "$LLAMA_TAG" https://github.com/ggml-org/llama.cpp.git "$SRC"
fi
actual=$(git -C "$SRC" rev-parse HEAD)
[ "$actual" = "$LLAMA_COMMIT" ] || { echo "$SRC is at $actual, expected $LLAMA_COMMIT; delete it and re-run" >&2; exit 1; }

# GGML_ASSERT bakes __FILE__ into the binary; map the checkout path away so releases don't carry
# the builder's home directory. Upstream hard-codes CMAKE_C_FLAGS, so patch a copy.
MAP="-ffile-prefix-map=$(cd "$SRC" && pwd -P)=llama.cpp"
sed -e "s#^COMMON_C_FLAGS=\"#COMMON_C_FLAGS=\"$MAP #" -e "s#^COMMON_CXX_FLAGS=\"#COMMON_CXX_FLAGS=\"$MAP #" \
    "$SRC/build-xcframework.sh" > "$SRC/build-xcframework-sotto.sh"
grep -q -- "$MAP" "$SRC/build-xcframework-sotto.sh" || { echo "couldn't patch build-xcframework.sh flags" >&2; exit 1; }
chmod +x "$SRC/build-xcframework-sotto.sh"
(cd "$SRC" && ./build-xcframework-sotto.sh macos)
rm -rf "$OUT"
cp -R "$SRC/build-apple/llama.xcframework" "$OUT"
# package-llama.sh (and the app's release.sh) compare this stamp with LLAMA_COMMIT: never ship a stale framework.
echo "$LLAMA_COMMIT" > "$OUT.commit"
echo "Built $OUT from llama.cpp $LLAMA_TAG ($LLAMA_COMMIT)"
# The engine manifest picks this path target when Vendor/llama.xcframework exists, but SwiftPM caches
# manifests by content, not by what's on disk: a checkout that already resolved the release asset keeps it.
echo "If this checkout already built against the release asset, use SOTTO_LLAMA_LOCAL=1 (or swift package purge-cache once) to link this one."
