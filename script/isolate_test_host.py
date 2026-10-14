#!/usr/bin/env python3
"""Stage an independently named XCTest host; never launch an AppPorts writer.

Run after build-for-testing, then pass the returned .xctestrun to xcodebuild
test-without-building. This changes only disposable build products.
"""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess


def stage(derived_data):
    products = Path(derived_data).resolve() / "Build/Products"
    source = products / "Debug/AppPorts.app"
    destination = products / "Debug/APLifecycleValidation.app"
    if not source.is_dir() or source.is_symlink():
        raise RuntimeError("Build the original test products first")
    if destination.exists():
        if destination.is_symlink():
            raise RuntimeError("Refusing a substituted test host")
        shutil.rmtree(destination)
    shutil.copytree(source, destination, symlinks=True)
    executable = destination / "Contents/MacOS/AppPorts"
    executable.rename(executable.with_name("APLifecycleValidation"))
    info = destination / "Contents/Info.plist"
    document = plistlib.loads(info.read_bytes())
    document.update(CFBundleExecutable="APLifecycleValidation",
                    CFBundleName="APLifecycleValidation",
                    CFBundleIdentifier="org.appports.validation.lifecycle")
    info.write_bytes(plistlib.dumps(document))
    # A changed Info.plist needs a new ad-hoc seal for XCTest injection. It has
    # a distinct identifier and never replaces or registers the installed app.
    subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(destination)], check=True)
    originals = list(products.glob("AppPorts_*.xctestrun"))
    if len(originals) != 1:
        raise RuntimeError("Expected exactly one architecture-specific test run")
    document = plistlib.loads(originals[0].read_bytes())

    def rewrite(value):
        if isinstance(value, dict):
            return {key: rewrite(item) for key, item in value.items()}
        if isinstance(value, list):
            return [rewrite(item) for item in value]
        if isinstance(value, str):
            value = value.replace("AppPorts.app", "APLifecycleValidation.app")
            if value == "com.shimoko.AppPorts":
                return "org.appports.validation.lifecycle"
        return value

    document = rewrite(document)
    for target in document.values():
        if isinstance(target, dict) and "ProcessNamesForCrashReportCollection" in target:
            target["ProcessNamesForCrashReportCollection"] = ["APLifecycleValidation"]
    result = products / "LifecycleValidation.xctestrun"
    result.write_bytes(plistlib.dumps(document))
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("derived_data", type=Path)
    args = parser.parse_args()
    print(stage(args.derived_data))
