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
  require_file SievePilotApp/Views/OutOfOfficeView.swift
  require_file SievePilotApp/Views/AccountSettingsView.swift
  require_file SievePilotAppTests/AppModelTests.swift
  require_file SievePilotAppTests/OutOfOfficeFlowTests.swift
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
  require_file Scripts/validate_xcode_project.py
  plutil -lint "$project" >/dev/null || fail "invalid project.pbxproj syntax"
  local project_json
  project_json=$(mktemp)
  plutil -convert json -o "$project_json" "$project"
  if ! python3 Scripts/validate_xcode_project.py "$project_json" "$scheme"; then
    rm -f "$project_json"
    return 1
  fi
  rm -f "$project_json"
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
