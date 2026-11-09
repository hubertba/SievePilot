#!/bin/bash
set -euo pipefail

mode=${1:-all}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "missing $1"
}

require_text() {
  local file=$1
  local text=$2
  grep -Fq "$text" "$file" || fail "$file does not contain: $text"
}

validate_sources() {
  require_file SievePilotApp/AppModel.swift
  require_file SievePilotApp/SievePilotApp.swift
  require_file SievePilotApp/Assets.xcassets/Contents.json
  require_file SievePilotApp/Assets.xcassets/AppIcon.appiconset/Contents.json
  require_file SievePilotAppTests/AppModelTests.swift
  require_text SievePilotApp/SievePilotApp.swift 'import SievePilotCore'
  require_text SievePilotApp/SievePilotApp.swift 'MenuBarExtra'
  require_text SievePilotApp/SievePilotApp.swift 'NSApplication.shared.terminate(nil)'
  echo 'Validated SievePilot app sources'
}

validate_project() {
  validate_sources
  local project=SievePilot.xcodeproj/project.pbxproj
  local scheme=SievePilot.xcodeproj/xcshareddata/xcschemes/SievePilot.xcscheme
  require_file "$project"
  require_file SievePilot.xcodeproj/project.xcworkspace/contents.xcworkspacedata
  require_file "$scheme"
  plutil -lint "$project" >/dev/null || fail "invalid project.pbxproj syntax"
  require_text "$project" 'productName = SievePilot;'
  require_text "$project" 'productName = SievePilotAppTests;'
  require_text "$project" 'AppModel.swift in Sources'
  require_text "$project" 'SievePilotApp.swift in Sources'
  require_text "$project" 'Assets.xcassets in Resources'
  require_text "$project" 'AppModelTests.swift in Sources'
  require_text "$project" 'relativePath = .;'
  require_text "$project" 'productName = SievePilotCore;'
  require_text "$project" 'SievePilotCore in Frameworks'
  require_text "$project" 'MACOSX_DEPLOYMENT_TARGET = 13.0;'
  require_text "$project" 'ONLY_ACTIVE_ARCH = YES;'
  require_text "$project" 'ENABLE_TESTABILITY = YES;'
  require_text "$project" 'GENERATE_INFOPLIST_FILE = YES;'
  require_text "$project" 'INFOPLIST_KEY_LSUIElement = YES;'
  require_text "$project" 'PRODUCT_BUNDLE_IDENTIFIER = com.hubertba.SievePilot;'
  require_text "$project" 'PRODUCT_BUNDLE_IDENTIFIER = com.hubertba.SievePilotTests;'
  require_text "$scheme" 'BlueprintIdentifier="400000000000000000000001"'
  require_text "$scheme" 'BlueprintIdentifier="400000000000000000000002"'
  echo 'Validated SievePilot Xcode project'
}

validate_documentation() {
  require_text README.md 'open SievePilot.xcodeproj'
  require_text README.md 'swift test'
  require_text README.md "xcodebuild test -project SievePilot.xcodeproj -scheme SievePilot -destination 'platform=macOS'"
  require_text .gitignore 'xcuserdata/'
  require_text .gitignore 'DerivedData/'
  echo 'Validated SievePilot developer documentation'
}

case "$mode" in
  sources) validate_sources ;;
  project) validate_project ;;
  all)
    validate_project
    validate_documentation
    ;;
  *) fail "unsupported validation mode: $mode" ;;
esac
