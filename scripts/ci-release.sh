#!/bin/bash
#
# CI Release Helper — consolidates release steps for GitHub Actions
#
# Usage:
#   ci-release.sh setup-keychain <base64-p12> <password>
#   ci-release.sh teardown-keychain
#   ci-release.sh codesign <app-path>
#   ci-release.sh codesign-dmg <dmg-path>
#   ci-release.sh notarize <app-path> <apple-id> <app-password> <team-id>
#   ci-release.sh create-dmg <app-path> <dmg-output-path>
#   ci-release.sh sparkle-sign <dmg-path> <tools-dir> <private-key>
#   ci-release.sh generate-appcast <dmg-path> <tools-dir> <version> <private-key>
#
# Designed for use in GitHub Actions. Can also be run locally for testing.

set -euo pipefail

KEYCHAIN_NAME="ci-signing.keychain-db"
KEYCHAIN_PASSWORD="ci-keychain-$(date +%s)"
SIGNING_IDENTITY="Developer ID Application"

# ── Helpers ──────────────────────────────────────────────────────────────

log() { echo "▸ $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ── Keychain ─────────────────────────────────────────────────────────────

cmd_setup_keychain() {
    local p12_base64="$1"
    local p12_password="$2"

    log "Creating temporary keychain"
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
    security set-keychain-settings -lut 21600 "$KEYCHAIN_NAME"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"

    log "Importing certificate"
    local p12_file
    p12_file=$(mktemp /tmp/cert.XXXXXX.p12)
    echo "$p12_base64" | base64 --decode > "$p12_file"

    security import "$p12_file" \
        -k "$KEYCHAIN_NAME" \
        -P "$p12_password" \
        -T /usr/bin/codesign \
        -T /usr/bin/productsign

    rm -f "$p12_file"

    log "Configuring keychain search list"
    security list-keychains -d user -s "$KEYCHAIN_NAME" $(security list-keychains -d user | tr -d '"')
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"

    log "Keychain ready"
}

cmd_teardown_keychain() {
    log "Removing temporary keychain"
    security delete-keychain "$KEYCHAIN_NAME" 2>/dev/null || true
}

# ── Code Signing ─────────────────────────────────────────────────────────

cmd_codesign() {
    local app_path="$1"

    [ -d "$app_path" ] || die "App not found: $app_path"

    log "Deep-signing $app_path"
    codesign --deep --force --options runtime \
        --sign "$SIGNING_IDENTITY" \
        --keychain "$KEYCHAIN_NAME" \
        "$app_path"

    log "Verifying signature"
    codesign --verify --deep --strict "$app_path"
    log "Signature valid"
}

cmd_codesign_dmg() {
    local dmg_path="$1"

    [ -f "$dmg_path" ] || die "DMG not found: $dmg_path"

    log "Signing DMG: $dmg_path"
    codesign --force --sign "$SIGNING_IDENTITY" \
        --keychain "$KEYCHAIN_NAME" \
        "$dmg_path"

    log "DMG signed"
}

# ── Notarization ─────────────────────────────────────────────────────────

cmd_notarize() {
    local app_path="$1"
    local apple_id="$2"
    local app_password="$3"
    local team_id="$4"

    [ -d "$app_path" ] || die "App not found: $app_path"

    local zip_path
    zip_path=$(mktemp /tmp/notarize.XXXXXX.zip)

    log "Creating ZIP for notarization"
    ditto -c -k --keepParent "$app_path" "$zip_path"

    log "Submitting to Apple notarization service"
    xcrun notarytool submit "$zip_path" \
        --apple-id "$apple_id" \
        --password "$app_password" \
        --team-id "$team_id" \
        --wait

    rm -f "$zip_path"

    log "Stapling notarization ticket"
    xcrun stapler staple "$app_path"

    log "Notarization complete"
}

# ── DMG Creation ─────────────────────────────────────────────────────────

cmd_create_dmg() {
    local app_path="$1"
    local dmg_path="$2"

    [ -d "$app_path" ] || die "App not found: $app_path"

    local app_name
    app_name=$(basename "$app_path" .app)

    local staging
    staging=$(mktemp -d /tmp/dmg-staging.XXXXXX)

    log "Creating DMG: $dmg_path"

    cp -R "$app_path" "$staging/"
    ln -s /Applications "$staging/Applications"

    hdiutil create \
        -volname "$app_name" \
        -srcfolder "$staging" \
        -ov \
        -format UDZO \
        "$dmg_path"

    rm -rf "$staging"

    log "DMG created: $(du -h "$dmg_path" | cut -f1)"
}

# ── Sparkle Signing ──────────────────────────────────────────────────────

cmd_sparkle_sign() {
    local dmg_path="$1"
    local tools_dir="$2"
    local private_key="$3"

    [ -f "$dmg_path" ] || die "DMG not found: $dmg_path"
    [ -x "$tools_dir/sign_update" ] || die "sign_update not found in: $tools_dir"

    log "Signing DMG with Sparkle EdDSA"

    local key_file
    key_file=$(mktemp /tmp/sparkle-key.XXXXXX)
    echo "$private_key" > "$key_file"

    local signature
    signature=$("$tools_dir/sign_update" "$dmg_path" --ed-key-file "$key_file")

    rm -f "$key_file"

    log "Sparkle signature: $signature"
    echo "$signature"
}

# ── Appcast Generation ───────────────────────────────────────────────────

cmd_generate_appcast() {
    local dmg_path="$1"
    local tools_dir="$2"
    local version="$3"
    local private_key="$4"

    [ -f "$dmg_path" ] || die "DMG not found: $dmg_path"
    [ -x "$tools_dir/generate_appcast" ] || die "generate_appcast not found in: $tools_dir"

    local repo_root
    repo_root="$(cd "$(dirname "$0")/.." && pwd)"

    local appcast_dir="$repo_root/build/appcast"
    mkdir -p "$appcast_dir"

    # Copy DMG to appcast staging directory
    cp "$dmg_path" "$appcast_dir/"

    log "Generating appcast.xml"

    local key_file
    key_file=$(mktemp /tmp/sparkle-key.XXXXXX)
    echo "$private_key" > "$key_file"

    local dmg_name
    dmg_name=$(basename "$dmg_path")

    "$tools_dir/generate_appcast" \
        --ed-key-file "$key_file" \
        --download-url-prefix "https://github.com/benedict2310/ora/releases/download/v${version}/" \
        -o "$appcast_dir/appcast.xml" \
        "$appcast_dir"

    rm -f "$key_file"

    log "Appcast generated at $appcast_dir/appcast.xml"
}

# ── Main Dispatch ────────────────────────────────────────────────────────

command="${1:-}"
shift || true

case "$command" in
    setup-keychain)     cmd_setup_keychain "$@" ;;
    teardown-keychain)  cmd_teardown_keychain ;;
    codesign)           cmd_codesign "$@" ;;
    codesign-dmg)       cmd_codesign_dmg "$@" ;;
    notarize)           cmd_notarize "$@" ;;
    create-dmg)         cmd_create_dmg "$@" ;;
    sparkle-sign)       cmd_sparkle_sign "$@" ;;
    generate-appcast)   cmd_generate_appcast "$@" ;;
    *)
        echo "Usage: $(basename "$0") <command> [args...]"
        echo ""
        echo "Commands:"
        echo "  setup-keychain <base64-p12> <password>  Import signing certificate"
        echo "  teardown-keychain                       Remove temporary keychain"
        echo "  codesign <app-path>                     Deep-sign app bundle"
        echo "  codesign-dmg <dmg-path>                 Sign DMG file"
        echo "  notarize <app> <id> <pw> <team>         Notarize with Apple"
        echo "  create-dmg <app-path> <dmg-path>        Create DMG from app"
        echo "  sparkle-sign <dmg> <tools> <key>        Sign with Sparkle EdDSA"
        echo "  generate-appcast <dmg> <tools> <ver> <key>  Generate appcast.xml"
        exit 1
        ;;
esac
