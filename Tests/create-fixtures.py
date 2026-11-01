#!/usr/bin/python3
import pathlib
import plistlib
import struct
import zipfile

root = pathlib.Path(__file__).resolve().parent.parent / "build/test-fixtures"
root.mkdir(exist_ok=True)
model = b"FPSENR1\0" + struct.pack("<II", 1, 4176) + bytes(64) + bytes(range(256)) * 16
for name, data in (("valid.bin", model), ("bad-tables.bin", model[:80] + bytes(4096)), ("mismatch.bin", model[:16] + b"mismatch" + model[24:])):
    path = root / name
    path.write_bytes(data)
    path.chmod(0o600)
with zipfile.ZipFile(root / "example.ipa", "w") as archive:
    archive.writestr("Payload/Example.app/Info.plist", plistlib.dumps({"CFBundleIdentifier": "test.example"}, fmt=plistlib.FMT_BINARY))
for folder, identifier in (("Installed/Seed.app/Wrapper/Seed.app", "test.seed"), ("Automatic/Example.app", "test.example")):
    app = root / folder
    app.mkdir(parents=True, exist_ok=True)
    (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier}))
