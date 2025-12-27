#!/bin/bash
#
# Ora Build Script
# Builds and optionally launches the Ora app
#
# Usage:
#   ./build.sh              # Build only
#   ./build.sh run          # Build and launch
#   ./build.sh clean        # Clean build
#   ./build.sh reset-perms  # Reset TCC permissions (after rebuild)
#

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

CONFIGURATION="Release"
SCHEME="Ora"
ARCH="arm64"
BUNDLE_ID="com.ora.app"

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

# Handle command
case "${1:-build}" in
  clean)
    echo -e "${YELLOW}Cleaning build artifacts...${NC}"
    rm -rf ~/Library/Developer/Xcode/DerivedData/Ora-*
    rm -rf build
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

  *)
    echo "Usage: $0 {build|run|clean|reset-perms}"
    echo ""
    echo "Commands:"
    echo "  build        Build the app (default)"
    echo "  run          Build and launch the app"
    echo "  clean        Remove build artifacts and generated project"
    echo "  reset-perms  Reset TCC permissions (use after rebuild)"
    exit 1
    ;;
esac
