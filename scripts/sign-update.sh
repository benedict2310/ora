#!/bin/bash
#
# Sign a Sparkle update archive with EdDSA and print signature/length.
#
# Usage:
#   ./scripts/sign-update.sh <version> <archive-path>
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION="${1:-}"
ARCHIVE_PATH="${2:-}"

if [ -z "$VERSION" ] || [ -z "$ARCHIVE_PATH" ]; then
    echo "Usage: $0 <version> <archive-path>"
    exit 1
fi

if [ ! -f "$ARCHIVE_PATH" ]; then
    echo "Error: Archive not found: $ARCHIVE_PATH"
    exit 1
fi

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

ARGS=()
if [ -n "${SPARKLE_KEYCHAIN_ACCOUNT:-}" ]; then
    ARGS+=(--account "$SPARKLE_KEYCHAIN_ACCOUNT")
fi
if [ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]; then
    ARGS+=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE")
fi

"$TOOLS_DIR/sign_update" "${ARGS[@]}" "$ARCHIVE_PATH"

echo "Signed update for version $VERSION"
