#!/usr/bin/env python3
"""Copy license notices for the exact Go modules linked into the bundled binaries."""
import pathlib
import re
import subprocess
import shutil

root = pathlib.Path(__file__).resolve().parent
destination = root / "dist/AppStore++.app/Contents/Resources/Licenses/Go-modules"
destination.mkdir(parents=True, exist_ok=True)
go = root / ".toolchain/go/bin/go"
if not go.exists():
    go = pathlib.Path(shutil.which("go") or "go")
manifest = []
for name in ("ipatool", "unfairplay"):
    metadata = subprocess.check_output([str(go), "version", "-m", str(root / "build/bin" / name)], text=True)
    for line in metadata.splitlines():
        fields = line.split()
        if not fields or fields[0] != "dep":
            continue
        module, version = fields[1:3]
        manifest.append(f"{name}: {module} {version}")
        escape = lambda value: re.sub(r"[A-Z]", lambda m: "!" + m[0].lower(), value)
        relative = escape(module) + "@" + escape(version)
        caches = (root / "vendor" / name / ".gomodcache", root / "build/go-modules", pathlib.Path(subprocess.check_output([str(go), "env", "GOMODCACHE"], text=True).strip()))
        source = next((cache / relative for cache in caches if (cache / relative).is_dir()), None)
        if source is None:
            raise SystemExit(f"Missing source/license directory for {module} {version}")
        target = destination / (module.replace("/", "_") + "@" + version)
        target.mkdir(exist_ok=True)
        notices = [p for p in source.iterdir() if p.is_file() and p.name.upper().startswith(("LICENSE", "UNLICENSE", "COPYING", "NOTICE", "AUTHORS", "PATENTS"))]
        if not notices:
            raise SystemExit(f"No license notice found for {module}")
        for notice in notices:
            (target / notice.name).write_bytes(notice.read_bytes())
(destination / "MODULES.txt").write_text("\n".join(sorted(set(manifest))) + "\n")
print(f"Bundled notices for {len(set(manifest))} linked module references.")
