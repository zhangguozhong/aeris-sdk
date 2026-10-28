#!/usr/bin/env python3
"""构建可分发的 ESM 与类型声明；临时包链接不会进入归档。"""
from pathlib import Path
import argparse
import subprocess
import shutil
import os

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument(
    "--typescript",
    default=os.environ.get(
        "AERIS_TYPESCRIPT", str(root / "tooling/node_modules/typescript/bin/tsc")
    ),
)
a = p.parse_args()
for name in ["client-core", "react-native", "web"]:
    package = root / "packages" / name
    link = package / "node_modules/aeris-client-core"
    created = False
    if name != "client-core":
        link.parent.mkdir(exist_ok=True)
        if not link.exists() and not link.is_symlink():
            link.symlink_to(root / "packages/client-core", target_is_directory=True)
            created = True
    try:
        subprocess.run(["node", a.typescript, "-p", str(package / "tsconfig.json")], check=True)
    finally:
        if created:
            link.unlink()
        if link.parent.exists() and not any(link.parent.iterdir()):
            link.parent.rmdir()
print("Built aeris-client-core, aeris-react-native and aeris-web ESM + declarations.")
