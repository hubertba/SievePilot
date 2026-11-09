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

case "$mode" in
  sources) validate_sources ;;
  *) fail "unsupported validation mode: $mode" ;;
esac
