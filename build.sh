#!/bin/bash
#
# Ora Build Script
# Builds, tests, and launches the Ora app
#
# Usage:
#   ./build.sh              # Build only
#   ./build.sh run          # Build and launch
#   ./build.sh clean        # Clean build
#   ./build.sh reset-perms  # Reset TCC permissions (after rebuild)
#   ./build.sh test         # Run tests with token-optimized output
#   ./build.sh test-perms   # Run tests with permission prompts enabled
#   ./build.sh test-tts     # Run on-demand TTS integration tests (audio)
#   ./build.sh test-tsan    # Run tests with Thread Sanitizer
#   ./build.sh logs         # Tail unified logs for Ora
#

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

CONFIGURATION="Release"
SCHEME="Ora"
SCHEME_TSAN="Ora-TSan"
ARCH="arm64"
BUNDLE_ID="com.ora.app"

# Artifacts directory for test results and logs
ARTIFACTS_DIR=".artifacts"
RESULT_BUNDLE="$ARTIFACTS_DIR/TestResults.xcresult"
RAW_LOG="$ARTIFACTS_DIR/xcodebuild.test.log"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}Ora Build Script${NC}"
echo ""

# Check if xcodegen is installed
check_xcodegen() {
  if ! command -v xcodegen &> /dev/null; then
    echo -e "${RED}Error: xcodegen is not installed${NC}"
    echo "Install with: brew install xcodegen"
    exit 1
  fi
}

# Generate Xcode project if needed
generate_project() {
  if [ ! -f "Ora.xcodeproj/project.pbxproj" ] || [ "project.yml" -nt "Ora.xcodeproj/project.pbxproj" ]; then
    echo -e "${BLUE}Generating Xcode project...${NC}"
    xcodegen generate
  fi
}

# Run tests with token-optimized output
run_tests() {
  local test_scheme="$1"
  shift
  local extra_args=("$@")
  local skip_prompts="${ORA_SKIP_PERMISSION_PROMPTS:-1}"
  
  check_xcodegen
  generate_project
  
  mkdir -p "$ARTIFACTS_DIR"
  rm -rf "$RESULT_BUNDLE"
  : > "$RAW_LOG"
  
  echo -e "${BLUE}Running tests (${test_scheme})...${NC}"
  
  set +e
  ORA_SKIP_PERMISSION_PROMPTS="$skip_prompts" xcodebuild \
    -project Ora.xcodeproj \
    -scheme "$test_scheme" \
    -derivedDataPath build \
    -resultBundlePath "$RESULT_BUNDLE" \
    -destination "platform=macOS,arch=${ARCH}" \
    "${extra_args[@]}" \
    -quiet \
    test \
    2>&1 | tee "$RAW_LOG"
  local status=${PIPESTATUS[0]}
  set -e
  
  # Token-optimized summary
  local summary_output=""
  local summary_status=0
  local tests_total=""
  local tests_passed=""
  if [ -f "scripts/xcresult_summary.py" ]; then
    set +e
    summary_output=$(python3 scripts/xcresult_summary.py "$RESULT_BUNDLE")
    summary_status=$?
    set -e
    if [ -n "$summary_output" ]; then
      echo "$summary_output"
      local summary_line
      summary_line=$(echo "$summary_output" | head -n 1)
      if [[ "$summary_line" =~ Tests:\ ([0-9]+)/([0-9]+)\ passed ]]; then
        tests_passed="${BASH_REMATCH[1]}"
        tests_total="${BASH_REMATCH[2]}"
      fi
    fi
  else
    # Fallback if script not available
    if [ $status -eq 0 ]; then
      echo -e "${GREEN}✅ Tests passed${NC}"
    else
      echo -e "${RED}❌ Tests failed${NC}"
    fi
  fi
  
  if [ $status -ne 0 ]; then
    local has_unhandled_resources=0
    if command -v rg &> /dev/null; then
      rg -q "Found unhandled resource" "$RAW_LOG" && has_unhandled_resources=1
    else
      grep -q "Found unhandled resource" "$RAW_LOG" && has_unhandled_resources=1
    fi
    if [ $summary_status -eq 0 ] && [ -n "$tests_total" ] && [ "$tests_total" -gt 0 ] && [ $has_unhandled_resources -eq 1 ]; then
      echo ""
      echo -e "${YELLOW}⚠️ xcodebuild exited with status $status due to SwiftPM unhandled resources; tests passed (${tests_passed}/${tests_total}).${NC}"
      exit 0
    fi
    echo ""
    echo -e "${YELLOW}Artifacts:${NC}"
    echo "  Raw log:       $RAW_LOG"
    echo "  Result bundle: $RESULT_BUNDLE"
    exit $status
  fi
}

# Handle command
case "${1:-build}" in
  clean)
    echo -e "${YELLOW}Cleaning build artifacts...${NC}"
    rm -rf ~/Library/Developer/Xcode/DerivedData/Ora-*
    rm -rf build
    rm -rf "$ARTIFACTS_DIR"
    rm -rf Ora.xcodeproj
    echo -e "${GREEN}Clean complete${NC}"
    exit 0
    ;;

  reset-perms)
    echo -e "${BLUE}Resetting TCC permissions for Ora...${NC}"
    echo -e "${YELLOW}Note: This is needed after rebuilding because TCC tracks permissions by CDHash.${NC}"
    tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
    tccutil reset Calendar "$BUNDLE_ID" 2>/dev/null || true
    tccutil reset Reminders "$BUNDLE_ID" 2>/dev/null || true
    tccutil reset AddressBook "$BUNDLE_ID" 2>/dev/null || true
    tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null || true
    echo -e "${GREEN}Permissions reset. Re-grant permissions on next use.${NC}"
    exit 0
    ;;

  build|run)
    check_xcodegen
    generate_project

    echo -e "${BLUE}Building Ora (${CONFIGURATION})...${NC}"

    # Create build directory
    mkdir -p build

    xcodebuild -project Ora.xcodeproj \
      -scheme "$SCHEME" \
      -configuration "$CONFIGURATION" \
      -arch "$ARCH" \
      -derivedDataPath build \
      ONLY_ACTIVE_ARCH=YES \
      build 2>&1 | grep -E "(BUILD|error:|warning:.*error|Signing)" || true

    BUILD_STATUS=${PIPESTATUS[0]}

    if [ $BUILD_STATUS -eq 0 ]; then
      echo -e "${GREEN}Build succeeded${NC}"

      APP_PATH="build/Build/Products/${CONFIGURATION}/Ora.app"
      echo -e "${BLUE}App location: ${APP_PATH}${NC}"

      if [ "$1" = "run" ]; then
        echo -e "${BLUE}Launching Ora...${NC}"
        # Kill existing instance
        killall Ora 2>/dev/null || true
        sleep 0.5
        # Launch new instance
        open "$APP_PATH"
        sleep 1

        # Check if running
        if pgrep -x Ora > /dev/null; then
          echo -e "${GREEN}Ora is running${NC}"
        else
          echo -e "${YELLOW}Ora may not have launched properly${NC}"
        fi
      fi
    else
      echo -e "${RED}Build failed${NC}"
      # Show full build output on failure
      xcodebuild -project Ora.xcodeproj \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -arch "$ARCH" \
        -derivedDataPath build \
        ONLY_ACTIVE_ARCH=YES \
        build 2>&1 | tail -50
      exit 1
    fi
    ;;

  test)
    rm -f "$HOME/Library/Application Support/Ora/run-tts-tests.flag"
    run_tests "$SCHEME"
    ;;

  test-perms|test-permissions)
    rm -f "$HOME/Library/Application Support/Ora/run-tts-tests.flag"
    ORA_SKIP_PERMISSION_PROMPTS=0 run_tests "$SCHEME"
    ;;

  test-tsan)
    rm -f "$HOME/Library/Application Support/Ora/run-tts-tests.flag"
    run_tests "$SCHEME_TSAN"
    ;;

  test-tts)
    TTS_FLAG_PATH="$HOME/Library/Application Support/Ora/run-tts-tests.flag"
    mkdir -p "$(dirname "$TTS_FLAG_PATH")"
    touch "$TTS_FLAG_PATH"
    trap 'rm -f "$TTS_FLAG_PATH"' EXIT
    run_tests "$SCHEME" -only-testing:OraTests/TTSIntegrationTests
    ;;

  logs)
    # Unified Logging tail for the app
    # NOTE: This command streams continuously until interrupted with Ctrl+C
    shift || true
    
    echo -e "${YELLOW}Streaming logs (Ctrl+C to stop)...${NC}"
    
    # Default: stream all logs for com.ora.app subsystem
    # Note: --level debug includes debug, info, and default levels
    if [ "${1:-}" = "--predicate" ]; then
      shift
      PRED="$1"; shift
      log stream --level debug --style json --predicate "$PRED" "$@"
    elif [ "${1:-}" = "--category" ]; then
      shift
      CAT="$1"; shift
      log stream --level debug --style json --predicate "subsystem == \"$BUNDLE_ID\" && category == \"$CAT\"" "$@"
    else
      log stream --level debug --style json --predicate "subsystem == \"$BUNDLE_ID\"" "$@"
    fi
    ;;

  open-results)
    if [ -d "$RESULT_BUNDLE" ]; then
      open "$RESULT_BUNDLE"
    else
      echo -e "${RED}No test results found at $RESULT_BUNDLE${NC}"
      echo "Run './build.sh test' first."
      exit 1
    fi
    ;;

  sign)
    echo -e "${BLUE}Building and signing Ora for distribution...${NC}"
    echo ""

    # Prompt for credentials
    read -p "Apple ID: " APPLE_ID
    read -sp "App-specific password: " APP_PASSWORD
    echo ""
    read -p "Team ID: " TEAM_ID
    read -p "Signing identity (or press Enter for 'Developer ID Application'): " SIGN_IDENTITY
    SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"

    echo ""
    echo -e "${YELLOW}Note: You may be prompted for your keychain password to access the signing certificate.${NC}"
    echo ""

    # Build
    check_xcodegen
    generate_project

    echo -e "${BLUE}Building Release configuration...${NC}"
    xcodebuild -project Ora.xcodeproj \
      -scheme "$SCHEME" \
      -configuration "$CONFIGURATION" \
      -arch "$ARCH" \
      -derivedDataPath build \
      ONLY_ACTIVE_ARCH=YES \
      CODE_SIGN_IDENTITY="-" \
      build 2>&1 | grep -E "(BUILD|error:|warning:.*error)" || true

    BUILD_STATUS=${PIPESTATUS[0]}
    [ $BUILD_STATUS -eq 0 ] || { echo -e "${RED}Build failed${NC}"; exit 1; }

    APP_PATH="build/Build/Products/${CONFIGURATION}/${SCHEME}.app"

    # Sign
    echo -e "${BLUE}Signing app bundle...${NC}"
    scripts/ci-release.sh codesign "$APP_PATH" || exit 1

    # Notarize
    echo -e "${BLUE}Notarizing (this takes 2-5 minutes)...${NC}"
    scripts/ci-release.sh notarize "$APP_PATH" "$APPLE_ID" "$APP_PASSWORD" "$TEAM_ID" || exit 1

    # Ask about DMG
    echo ""
    read -p "Create DMG? (y/N): " CREATE_DMG
    if [[ "$CREATE_DMG" =~ ^[Yy]$ ]]; then
      VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0.0")
      DMG_PATH="$PWD/Ora-${VERSION}.dmg"

      echo -e "${BLUE}Creating DMG...${NC}"
      scripts/ci-release.sh create-dmg "$APP_PATH" "$DMG_PATH" || exit 1
      scripts/ci-release.sh codesign-dmg "$DMG_PATH" || exit 1

      echo -e "${GREEN}DMG created and signed: $DMG_PATH${NC}"
    fi

    echo ""
    echo -e "${GREEN}✅ Signed and notarized app: $APP_PATH${NC}"
    echo -e "${YELLOW}You can now distribute this build or test it locally.${NC}"
    ;;

  *)
    echo "Usage: $0 {build|run|clean|reset-perms|test|test-perms|test-tsan|test-tts|logs|open-results|sign}"
    echo ""
    echo "Commands:"
    echo "  build         Build the app (default)"
    echo "  run           Build and launch the app"
    echo "  clean         Remove build artifacts and generated project"
    echo "  reset-perms   Reset TCC permissions (use after rebuild)"
    echo "  test          Run tests with token-optimized output"
    echo "  test-perms    Run tests with permission prompts enabled"
    echo "  test-tsan     Run tests with Thread Sanitizer enabled"
    echo "  test-tts      Run on-demand TTS integration tests (audio)"
    echo "  logs          Tail unified logs (Ctrl+C to stop; --category <name> or --predicate <expr>)"
    echo "  open-results  Open the .xcresult bundle in Xcode"
    echo "  sign          Build, sign with Developer ID, notarize, and optionally create DMG"
    exit 1
    ;;
esac
