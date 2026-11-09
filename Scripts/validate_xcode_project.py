#!/usr/bin/env python3
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"ERROR: {message}")


project_path, scheme_path = map(Path, sys.argv[1:3])
project = json.loads(project_path.read_text())
objects = project["objects"]


def target_named(name: str) -> tuple[str, dict]:
    matches = [
        (identifier, value)
        for identifier, value in objects.items()
        if value.get("isa") == "PBXNativeTarget" and value.get("name") == name
    ]
    require(len(matches) == 1, f"expected one native target named {name}")
    return matches[0]


def phase(target: dict, kind: str) -> dict:
    matches = [objects[identifier] for identifier in target.get("buildPhases", [])
               if objects[identifier].get("isa") == kind]
    require(len(matches) == 1, f"expected one {kind} for {target.get('name')}")
    return matches[0]


def phase_reference_ids(target: dict, kind: str) -> set[str]:
    result: set[str] = set()
    for build_file_id in phase(target, kind).get("files", []):
        build_file = objects[build_file_id]
        reference_id = build_file.get("fileRef") or build_file.get("productRef")
        require(reference_id in objects, f"unresolved build file reference {build_file_id}")
        result.add(reference_id)
    return result


def phase_items(target: dict, kind: str) -> set[str]:
    result: set[str] = set()
    for reference_id in phase_reference_ids(target, kind):
        reference = objects[reference_id]
        item = reference.get("path") or reference.get("productName") or reference.get("name")
        require(item is not None, f"unnamed build phase item {reference_id}")
        result.add(item)
    return result


def configurations(target: dict) -> dict[str, dict]:
    config_list = objects[target["buildConfigurationList"]]
    result = {
        objects[identifier]["name"]: objects[identifier]["buildSettings"]
        for identifier in config_list.get("buildConfigurations", [])
    }
    require(set(result) == {"Debug", "Release"},
            f"{target.get('name')} must have Debug and Release configurations")
    return result


app_id, app = target_named("SievePilot")
test_id, tests = target_named("SievePilotAppTests")

require({"AppModel.swift", "SievePilotApp.swift"}.issubset(
    phase_items(app, "PBXSourcesBuildPhase")),
    "app target source membership is incomplete")
require("Assets.xcassets" in phase_items(app, "PBXResourcesBuildPhase"),
        "app target does not contain Assets.xcassets")
require("AppModelTests.swift" in phase_items(tests, "PBXSourcesBuildPhase"),
        "test target does not contain AppModelTests.swift")
framework_products = phase_reference_ids(app, "PBXFrameworksBuildPhase")
package_products = set(app.get("packageProductDependencies", []))
linked_core_products = {
    identifier for identifier in framework_products & package_products
    if objects[identifier].get("productName") == "SievePilotCore"
}
require(len(linked_core_products) == 1,
        "app target must link its SievePilotCore package product dependency")

root = objects[project["rootObject"]]
local_package_ids = {
    identifier for identifier in root.get("packageReferences", [])
    if objects[identifier].get("isa") == "XCLocalSwiftPackageReference"
    and objects[identifier].get("relativePath") == "."
}
require(local_package_ids, "project lacks a root local package reference")
linked_core_id = next(iter(linked_core_products))
require(objects[linked_core_id].get("package") in local_package_ids,
        "SievePilotCore product is not supplied by the root local package")

for name, settings in configurations(app).items():
    require(settings.get("MACOSX_DEPLOYMENT_TARGET") == "13.0",
            f"app {name} deployment target must be 13.0")
    require(settings.get("GENERATE_INFOPLIST_FILE") == "YES",
            f"app {name} must generate its Info.plist")
    require(settings.get("INFOPLIST_KEY_LSUIElement") == "YES",
            f"app {name} must set LSUIElement")
    require(settings.get("PRODUCT_BUNDLE_IDENTIFIER") == "com.hubertba.SievePilot",
            f"app {name} has the wrong bundle identifier")

for name, settings in configurations(tests).items():
    require(settings.get("MACOSX_DEPLOYMENT_TARGET") == "13.0",
            f"test {name} deployment target must be 13.0")
    require(settings.get("GENERATE_INFOPLIST_FILE") == "YES",
            f"test {name} must generate its Info.plist")
    require(settings.get("PRODUCT_BUNDLE_IDENTIFIER") == "com.hubertba.SievePilotTests",
            f"test {name} has the wrong bundle identifier")

project_configs = configurations(root)
require(project_configs["Debug"].get("ONLY_ACTIVE_ARCH") == "YES",
        "project Debug must build only the active architecture")
require(project_configs["Debug"].get("ENABLE_TESTABILITY") == "YES",
        "project Debug must enable testability")

try:
    scheme = ET.parse(scheme_path).getroot()
except ET.ParseError as error:
    raise SystemExit(f"ERROR: malformed shared scheme: {error}") from error

expected_container = "container:SievePilot.xcodeproj"
build_entries: dict[str, tuple[ET.Element, ET.Element]] = {}
for entry in scheme.findall("./BuildAction/BuildActionEntries/BuildActionEntry"):
    reference = entry.find("BuildableReference")
    if reference is not None:
        build_entries[reference.get("BlueprintIdentifier", "")] = (entry, reference)

for identifier, name in ((app_id, "app"), (test_id, "test")):
    require(identifier in build_entries, f"shared scheme does not build the {name} target")
    entry, reference = build_entries[identifier]
    require(reference.get("ReferencedContainer") == expected_container,
            f"shared scheme {name} target references the wrong container")
    require(entry.get("buildForTesting") == "YES",
            f"shared scheme {name} target is not enabled for testing")

app_entry, _ = build_entries[app_id]
require(app_entry.get("buildForRunning") == "YES",
        "shared scheme app target is not enabled for running")

test_references = scheme.findall("./TestAction/Testables/TestableReference")
valid_test_reference = False
for test_reference in test_references:
    reference = test_reference.find("BuildableReference")
    if (reference is not None
            and reference.get("BlueprintIdentifier") == test_id
            and reference.get("ReferencedContainer") == expected_container
            and test_reference.get("skipped") == "NO"):
        valid_test_reference = True
require(valid_test_reference,
        "shared scheme TestAction lacks a non-skipped app-test target")
