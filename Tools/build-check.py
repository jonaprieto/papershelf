#!/usr/bin/env python3
"""Check bundle replacement on scratch apps, without installing or opening anything."""
import pathlib
import json
import plistlib
import shutil
import subprocess
import tempfile
import uuid

root = pathlib.Path(__file__).resolve().parent.parent


def run(*args, succeeds=True):
    result = subprocess.run(args, capture_output=True, text=True)
    assert (result.returncode == 0) == succeeds, result.stdout + result.stderr


with tempfile.TemporaryDirectory(prefix="papershelf-build-check-") as scratch:
    scratch = pathlib.Path(scratch)
    source = scratch / "Source.app"
    destination = scratch / "Installed.app"
    contents = source / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    shutil.copy("/usr/bin/true", contents / "MacOS" / "PaperShelf")
    info = {
        "CFBundleIdentifier": "com.jonaprieto.pdfhammer",
        "CFBundleExecutable": "PaperShelf",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.14.1",
        "CFBundleVersion": "23",
        "PaperShelfBuildChannel": "development",
        "PaperShelfBuildID": str(uuid.uuid4()),
        "PaperShelfBuiltAt": "2026-09-08T12:00:00Z",
    }

    def sign():
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        run("/usr/bin/codesign", "--force", "--sign", "-", str(source))

    def installed_id():
        return plistlib.loads((destination / "Contents/Info.plist").read_bytes())["PaperShelfBuildID"]

    record = scratch / "cache/development-build.json"
    publish = ["swift", str(root / "Tools/publish-app.swift"), str(source), str(destination),
               "--record", str(record)]
    sign()
    run(*publish)
    first = installed_id()
    assert first == info["PaperShelfBuildID"]
    info["PaperShelfBuildID"] = str(uuid.uuid4())
    sign()
    run(*publish)
    second = installed_id()
    assert second != first and second == info["PaperShelfBuildID"]
    assert json.loads(record.read_text())["buildID"] == second
    assert json.loads(record.read_text())["bundlePath"] == str(destination)
    run("/usr/bin/codesign", "--verify", "--strict", str(destination))
    assert source.exists(), "Publishing must preserve the build copied into an installation"

    # A tampered bundle and an incomplete one must leave the installed copy untouched.
    info["PaperShelfBuildID"] = str(uuid.uuid4())
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    run(*publish, succeeds=False)
    assert installed_id() == second
    assert json.loads(record.read_text())["buildID"] == second
    del info["PaperShelfBuildID"]
    sign()
    run(*publish, succeeds=False)
    assert installed_id() == second

print("Bundle replacement checks passed")
