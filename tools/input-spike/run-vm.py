#!/usr/bin/env python3
"""SPIKE ONLY: run the input-host measurements in a disposable clone of the UI test VM.

Not shipped and not part of any app target; see docs/input-host-spike.md. The bundles are built
and signed on the host (the guest has no signing identity), then shipped into a throwaway clone of
`volant-ui-xcode` (macOS 15.7.7, SIP disabled in that image) so TCC grants, a System Settings
password sheet and synthesized input never touch the owner's Mac or the shared test VM. The clone
is deleted afterwards.

`--with-host-apps` zips the host's installed Google Chrome and Obsidian bundles (no download) so
the guest can test a Chromium browser and an Electron app.
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
SPIKE = ROOT / "tools" / "input-spike"
parser = argparse.ArgumentParser()
parser.add_argument("--source-vm", default=os.environ.get("VOLANT_UI_VM", "volant-ui-xcode"))
parser.add_argument("--clone", default="volant-input-spike")
parser.add_argument("--with-host-apps", action="store_true")
args = parser.parse_args()

output = Path(tempfile.mkdtemp(prefix="volant-input-spike-"))
print(f"Spike artifacts: {output}", flush=True)

vms = {vm["Name"]: vm for vm in json.loads(subprocess.check_output(["tart", "list", "--format", "json"]))}
if args.source_vm not in vms:
    raise SystemExit(f"Prepare {args.source_vm} using docs/ui-testing.md. Nothing was run on the host.")
if any(vm["Running"] for vm in vms.values() if vm["Source"] == "local"):
    raise SystemExit("A local Tart VM is running; wait for its work to finish rather than start a second VM.")
if args.clone in vms:
    raise SystemExit(f"{args.clone} already exists; delete it first (tart delete {args.clone}).")

for name, build, identity in [("b1", "1", None), ("b2", "2", None), ("a1", "1", "-"), ("a2", "2", "-")]:
    command = [str(SPIKE / "build.sh"), str(output / name), build] + ([identity] if identity else [])
    subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["ditto", "-c", "-k", "--keepParent", str(output / name / "Input Spike.app"), str(output / f"{name}.zip")], check=True)
for path in (SPIKE / "guest").iterdir():
    shutil.copy(path, output / path.name)
if args.with_host_apps:
    for app, archive in [("/Applications/Google Chrome.app", "chrome.zip"), ("/Applications/Obsidian.app", "obsidian.zip")]:
        if Path(app).exists():
            subprocess.run(["ditto", "-c", "-k", "--keepParent", app, str(output / archive)], check=True)
key = output / "ssh-key"
subprocess.run(["ssh-keygen", "-t", "ed25519", "-N", "", "-q", "-f", str(key)], check=True)

subprocess.run(["tart", "clone", args.source_vm, args.clone], check=True)
log = (output / "tart.log").open("w")
process = subprocess.Popen(["tart", "run", args.clone, "--no-graphics", "--no-audio", "--no-clipboard", f"--dir=artifacts:{output}"],
                           stdout=log, stderr=subprocess.STDOUT)
guest = "/Volumes/My Shared Files/artifacts"


def tart_exec(script, *extra, record):
    """Runs a guest script through the Tart agent and appends its output to the record."""
    with record.open("a") as handle:
        handle.write(f"\n######## {script} {' '.join(extra)}\n")
        handle.flush()
        subprocess.run(["tart", "exec", args.clone, "/bin/bash", f"{guest}/{script}", *extra],
                       stdout=handle, stderr=subprocess.STDOUT, timeout=1800, check=False)


def ssh_exec(address, script, *extra, record):
    """Runs a guest script over SSH, whose responsible process holds the image's UI-scripting grant."""
    with record.open("a") as handle:
        handle.write(f"\n######## (ssh) {script} {' '.join(extra)}\n")
        handle.flush()
        subprocess.run(["ssh", "-i", str(key), "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                        "-o", "LogLevel=ERROR", f"admin@{address}", f"bash '{guest}/{script}' {' '.join(extra)}"],
                       stdout=handle, stderr=subprocess.STDOUT, timeout=600, check=False)


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
    record = output / "spike.log"
    tart_exec("phase1-before-grant.sh", record=record)
    ssh_exec(address, "grant.sh", "10", record=record)
    tart_exec("phase2-after-grant.sh", record=record)
    tart_exec("phase3-adhoc.sh", "request", record=record)
    ssh_exec(address, "grant.sh", "30", record=record)
    tart_exec("phase3-adhoc.sh", "check", record=record)
finally:
    subprocess.run(["tart", "stop", args.clone], check=False, timeout=120)
    process.wait(timeout=120)
    log.close()
    subprocess.run(["tart", "delete", args.clone], check=False)
    for archive in ("chrome.zip", "obsidian.zip"):
        (output / archive).unlink(missing_ok=True)

print((output / "spike.log").read_text())
print(f"Screenshots: {output / 'shots'}")
