#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT

make_fixture() {
  local destination=$1
  mkdir -p "$destination/Scripts"
  cp -R "$repo/SievePilot.xcodeproj" "$destination/"
  cp -R "$repo/SievePilotApp" "$destination/"
  cp -R "$repo/SievePilotAppTests" "$destination/"
  cp "$repo/Scripts/validate-xcode-project.sh" "$repo/Scripts/validate_xcode_project.py" "$destination/Scripts/"
  cp "$repo/README.md" "$repo/.gitignore" "$destination/"
}

expect_rejected() {
  local name=$1
  local mutation=$2
  local fixture="$temp/$name"
  make_fixture "$fixture"
  (cd "$fixture" && eval "$mutation")
  if (cd "$fixture" && bash Scripts/validate-xcode-project.sh all >/dev/null 2>&1); then
    echo "ERROR: validator accepted mutation: $name" >&2
    exit 1
  fi
  echo "Rejected mutation: $name"
}

baseline="$temp/baseline"
make_fixture "$baseline"
(cd "$baseline" && bash Scripts/validate-xcode-project.sh all >/dev/null)

expect_rejected missing-app-source \
  "python3 -c \"from pathlib import Path; p=Path('SievePilot.xcodeproj/project.pbxproj'); s=p.read_text(); p.write_text(s.replace('\\t\\t\\t\\t100000000000000000000001 /* AppModel.swift in Sources */,\\n', '', 1))\""

expect_rejected missing-core-framework-link \
  "python3 -c \"from pathlib import Path; p=Path('SievePilot.xcodeproj/project.pbxproj'); s=p.read_text(); p.write_text(s.replace('\\t\\t\\t\\t100000000000000000000005 /* SievePilotCore in Frameworks */,\\n', '', 1))\""

expect_rejected missing-package-product-dependency \
  "python3 -c \"from pathlib import Path; p=Path('SievePilot.xcodeproj/project.pbxproj'); s=p.read_text(); p.write_text(s.replace('\\t\\t\\t\\t900000000000000000000002 /* SievePilotCore */,\\n', '', 1))\""

expect_rejected framework-product-not-owned-by-target \
  "python3 -c \"from pathlib import Path; p=Path('SievePilot.xcodeproj/project.pbxproj'); s=p.read_text().replace('productRef = 900000000000000000000002 /* SievePilotCore */;', 'productRef = 900000000000000000000003 /* SievePilotCore duplicate */;', 1); marker='/* End XCSwiftPackageProductDependency section */'; duplicate='\\t\\t900000000000000000000003 /* SievePilotCore duplicate */ = {isa = XCSwiftPackageProductDependency; package = 900000000000000000000001; productName = SievePilotCore; };\\n'; p.write_text(s.replace(marker, duplicate + marker, 1))\""

expect_rejected wrong-debug-deployment-target \
  "python3 -c \"from pathlib import Path; p=Path('SievePilot.xcodeproj/project.pbxproj'); s=p.read_text(); old='\\t\\t\\t\\tMACOSX_DEPLOYMENT_TARGET = 13.0;\\n\\t\\t\\t\\tMARKETING_VERSION = 1.0;'; p.write_text(s.replace(old, old.replace('13.0', '14.0'), 1))\""

expect_rejected missing-release-accessory-setting \
  "python3 -c \"from pathlib import Path; p=Path('SievePilot.xcodeproj/project.pbxproj'); s=p.read_text(); needle='\\t\\t\\t\\tINFOPLIST_KEY_LSUIElement = YES;\\n'; i=s.rfind(needle); p.write_text(s[:i] + s[i+len(needle):])\""

expect_rejected broken-scheme-container \
  "python3 -c \"from pathlib import Path; p=Path('SievePilot.xcodeproj/xcshareddata/xcschemes/SievePilot.xcscheme'); s=p.read_text(); p.write_text(s.replace('ReferencedContainer=\\\"container:SievePilot.xcodeproj\\\"', 'ReferencedContainer=\\\"container:Missing.xcodeproj\\\"', 1))\""

expect_rejected missing-test-action \
  "python3 -c \"from pathlib import Path; p=Path('SievePilot.xcodeproj/xcshareddata/xcschemes/SievePilot.xcscheme'); s=p.read_text().replace('<TestAction ', '<BrokenTestAction ', 1).replace('</TestAction>', '</BrokenTestAction>', 1); p.write_text(s)\""

echo 'All validator mutation tests passed'
