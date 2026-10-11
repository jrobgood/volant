#!/usr/bin/env python3
"""Run the input helper's end-to-end checks in a disposable clone of the UI test VM.

The harness (tools/input-host-e2e/build.sh) is built and Developer ID signed on the host, then
shipped into a throwaway clone of `volant-ui-xcode` so the Accessibility grant, the System Settings
password sheet and synthesized input never touch the owner's Mac or the shared test VM itself. The
clone is deleted afterwards. `--with-chrome` zips the host's installed Google Chrome (no download).
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = ROOT / "tools" / "input-host-e2e"
parser = argparse.ArgumentParser()
parser.add_argument("--source-vm", default=os.environ.get("VOLANT_UI_VM", "volant-ui-xcode"))
parser.add_argument("--clone", default="volant-input-e2e")
parser.add_argument("--with-chrome", action="store_true")
parser.add_argument("--build", help="an existing build.sh output directory")
parser.add_argument("--keep", action="store_true", help="leave the clone running for follow-up checks; delete it yourself")
args = parser.parse_args()

output = Path(tempfile.mkdtemp(prefix="volant-input-e2e-"))
print(f"Artifacts: {output}", flush=True)

vms = {vm["Name"]: vm for vm in json.loads(subprocess.check_output(["tart", "list", "--format", "json"]))}
if args.source_vm not in vms:
    raise SystemExit(f"Prepare {args.source_vm} using docs/ui-testing.md. Nothing was run on the host.")
if any(vm["Running"] for vm in vms.values() if vm["Source"] == "local"):
    raise SystemExit("A local Tart VM is running; wait for its work to finish rather than start a second VM.")
if args.clone in vms:
    raise SystemExit(f"{args.clone} already exists; delete it first (tart delete {args.clone}).")

build = Path(args.build) if args.build else output / "build"
if not args.build:
    subprocess.run([str(HERE / "build.sh"), str(build)], check=True)
subprocess.run(["ditto", "-c", "-k", "--keepParent", str(build / "Volant.app"), str(output / "volant.zip")], check=True)
for path in (HERE / "guest").iterdir():
    shutil.copy(path, output / path.name)
if args.with_chrome and Path("/Applications/Google Chrome.app").exists():
    subprocess.run(["ditto", "-c", "-k", "--keepParent", "/Applications/Google Chrome.app", str(output / "chrome.zip")], check=True)
key = output / "ssh-key"
subprocess.run(["ssh-keygen", "-t", "ed25519", "-N", "", "-q", "-f", str(key)], check=True)

subprocess.run(["tart", "clone", args.source_vm, args.clone], check=True)
log = (output / "tart.log").open("w")
process = subprocess.Popen(["tart", "run", args.clone, "--no-graphics", "--no-audio", "--no-clipboard", f"--dir=artifacts:{output}"],
                           stdout=log, stderr=subprocess.STDOUT)
guest = "/Volumes/My Shared Files/artifacts"
address = "(unknown)"
try:
    deadline = time.time() + 300
    while subprocess.run(["tart", "exec", args.clone, "/usr/bin/true"], stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, timeout=15).returncode != 0:
        if process.poll() is not None or time.time() > deadline:
            raise RuntimeError(f"Guest did not become reachable; see {output / 'tart.log'}")
        time.sleep(5)
    subprocess.run(["tart", "exec", args.clone, "/bin/bash", "-c",
                    f"mkdir -p ~/.ssh && cat '{guest}/ssh-key.pub' >> ~/.ssh/authorized_keys"], check=True)
    address = subprocess.check_output(["tart", "ip", args.clone], text=True).strip()
    with (output / "e2e.log").open("w") as handle:
        subprocess.run(["ssh", "-i", str(key), "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                        "-o", "LogLevel=ERROR", f"admin@{address}", f"bash '{guest}/e2e.sh'"],
                       stdout=handle, stderr=subprocess.STDOUT, timeout=1800, check=False)
finally:
    if args.keep:
        print(f"Kept {args.clone} running for follow-up checks: ssh -i {key} admin@{address}. "
              f"Afterwards run: tart stop {args.clone} && tart delete {args.clone}", flush=True)
    else:
        subprocess.run(["tart", "stop", args.clone], check=False, timeout=120)
        process.wait(timeout=120)
        subprocess.run(["tart", "delete", args.clone], check=False)
        (output / "chrome.zip").unlink(missing_ok=True)
    log.close()

print((output / "e2e.log").read_text())
print(f"Screenshots: {output / 'shots'}")
