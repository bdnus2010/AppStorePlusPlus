#!/usr/bin/python3
"""Deterministic workflow fake: no FairPlay data, Apple access, or real decryption."""
import json
import pathlib
import struct
import sys
import zipfile
import plistlib

args = sys.argv[1:]
def value(flag):
    return pathlib.Path(args[args.index(flag) + 1])
def model():
    return b"FPSENR1\0" + struct.pack("<II", 1, 4176) + bytes(64) + bytes(range(256)) * 16
if args[0] == "doctor":
    data = value("--model").read_bytes()
    valid = len(data) == 4176 and data[:8] == b"FPSENR1\0" and data[80:] == bytes(range(256)) * 16
    print(json.dumps({"checks": {"model_valid": valid}}, indent=2))
    sys.exit(0 if valid else 1)
elif args[0] == "recover":
    output = value("--output")
    output.mkdir(mode=0o700)
    path = output / "fairplay-enrollment.bin"
    path.write_bytes(model())
    path.chmod(0o600)
    print(json.dumps({"success": True}))
elif args[0] == "decrypt":
    source, output = value("--input"), value("--output")
    with zipfile.ZipFile(source) as archive:
        bundle_id = plistlib.loads(archive.read("Payload/Example.app/Info.plist"))["CFBundleIdentifier"]
    if bundle_id == "test.failure":
        print("error: synthetic decryption failure", file=sys.stderr)
        sys.exit(1)
    if value("--model").read_bytes()[16:24] == b"mismatch":
        print("error: enrollment model is bound to selector 1, but IPA has 2", file=sys.stderr)
        sys.exit(1)
    if output.exists():
        sys.exit(1)
    output.write_bytes(b"mock decrypted " + source.read_bytes())
    value("--report").write_text('{"success":true}')
    print(json.dumps({"success": True}))
elif args[0] == "verify":
    print(json.dumps({"success": True}))
else:
    sys.exit(1)
