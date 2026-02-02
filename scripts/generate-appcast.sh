#!/bin/bash
#
# Generate or update Sparkle appcast.xml
#
# Usage:
#   ./scripts/generate-appcast.sh [archives-dir]
#   ./scripts/generate-appcast.sh --print-tools-dir
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

print_tools_dir=0
if [ "${1:-}" = "--print-tools-dir" ]; then
    print_tools_dir=1
    shift
fi

ARCHIVES_DIR="${1:-$REPO_ROOT/updates}"

resolve_tools_dir() {
    if [ -n "${SPARKLE_TOOLS_DIR:-}" ] && [ -d "$SPARKLE_TOOLS_DIR" ]; then
        echo "$SPARKLE_TOOLS_DIR"
        return 0
    fi

    local build_tools="$REPO_ROOT/build/SourcePackages/artifacts/sparkle/Sparkle/bin"
    if [ -d "$build_tools" ]; then
        echo "$build_tools"
        return 0
    fi

    local derived_dir="${DERIVED_DATA_DIR:-$HOME/Library/Developer/Xcode/DerivedData}"
    local found
    found=$(find "$derived_dir" -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin" -type d 2>/dev/null | head -n 1 || true)
    if [ -n "$found" ]; then
        echo "$found"
        return 0
    fi

    return 1
}

TOOLS_DIR=$(resolve_tools_dir || true)
if [ -z "$TOOLS_DIR" ]; then
    echo "Error: Sparkle tools not found. Build once or set SPARKLE_TOOLS_DIR."
    exit 1
fi

if [ $print_tools_dir -eq 1 ]; then
    echo "$TOOLS_DIR"
    exit 0
fi

if [ ! -d "$ARCHIVES_DIR" ]; then
    echo "Error: Archives directory not found: $ARCHIVES_DIR"
    exit 1
fi

ARGS=()
if [ -n "${SPARKLE_KEYCHAIN_ACCOUNT:-}" ]; then
    ARGS+=(--account "$SPARKLE_KEYCHAIN_ACCOUNT")
fi
if [ -n "${SPARKLE_DOWNLOAD_URL_PREFIX:-}" ]; then
    ARGS+=(--download-url-prefix "$SPARKLE_DOWNLOAD_URL_PREFIX")
fi
if [ -n "${SPARKLE_RELEASE_NOTES_URL_PREFIX:-}" ]; then
    ARGS+=(--release-notes-url-prefix "$SPARKLE_RELEASE_NOTES_URL_PREFIX")
fi

"$TOOLS_DIR/generate_appcast" -o "$ARCHIVES_DIR/appcast.xml" "${ARGS[@]}" "$ARCHIVES_DIR"

echo "Appcast updated at $ARCHIVES_DIR/appcast.xml"
