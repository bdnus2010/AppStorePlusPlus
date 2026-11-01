#!/usr/bin/python3
"""Local fake helper for UI-model tests. Never contacts Apple or Keychain."""
import json
import sys
import pathlib
import plistlib
import zipfile

args = sys.argv[1:]
if "login" in args:
    credentials = json.load(sys.stdin)
    code = credentials.get("AuthCode", "")
    if not code:
        print(json.dumps({"message": "2FA code is required; run the command again and supply a code"}))
    elif code != "123456":
        print(json.dumps({"success": False, "error": "Invalid verification code; try a fresh code"}))
        sys.exit(1)
    else:
        print(json.dumps({"success": True, "email": credentials["Email"]}))
elif "search" in args:
    print(json.dumps({"count": 1, "apps": [{"id": 123, "name": "Example", "bundleID": "test.example", "version": args[args.index("--platform") + 1]}]}))
elif "revoke" in args:
    print(json.dumps({"success": True}))
elif "download" in args:
    if "--app-id" in args and args[args.index("--app-id") + 1] == "998":
        print(json.dumps({"success": False, "error": "license is required"}))
        sys.exit(1)
    output = pathlib.Path(args[args.index("--output") + 1])
    if "--bundle-identifier" in args:
        bundle_id = args[args.index("--bundle-identifier") + 1]
    else:
        bundle_id = "test.failure" if args[args.index("--app-id") + 1] == "999" else "test.example"
    with zipfile.ZipFile(output, "w") as archive:
        archive.writestr("Payload/Example.app/Info.plist", plistlib.dumps({"CFBundleIdentifier": bundle_id, "TestPlatform": args[args.index("--platform") + 1]}, fmt=plistlib.FMT_BINARY))
    print(json.dumps({"success": True, "output": str(output)}))
else:
    sys.exit(1)
