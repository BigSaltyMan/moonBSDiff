"""Run the fixed offline update demo with an explicit MoonBSDiff CLI."""

import argparse
import bz2
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

from build_cli import ROOT
from check_apply import integer


UPSTREAM = ROOT / "testdata/upstream/seeded-random"
TARGET_SHA256 = "66da6542f8276608790055ac88e6af6bf3af76b88bf3aedbcb517c2ce98ab1a6"


def prepare_two_hop(write, invoke):
    start = (UPSTREAM / "old.bin").read_bytes()
    middle = (UPSTREAM / "new.bin").read_bytes()
    target = middle[:-1] + bytes([middle[-1] ^ 1])
    write("installed.bin", start)
    write("v2.bin", middle)
    write("v3.bin", target)
    write("v1-to-v2.patch", (UPSTREAM / "patch.bin").read_bytes())
    invoke("manifest", "create", "installed.bin", "v2.bin", "v1-to-v2.patch", "v1-to-v2.json")
    invoke("diff", "--manifest", "v2-to-v3.json", "v2.bin", "v3.bin", "v2-to-v3.patch")
    return start, middle, target


def prepare_direct(write, invoke, target):
    # Valid BSDIFF40, deliberately carrying all target bytes in Extra.
    control = bz2.compress(integer(0) + integer(len(target)) + integer(0))
    delta = bz2.compress(b"")
    extra = bz2.compress(target)
    header = b"BSDIFF40" + integer(len(control)) + integer(len(delta)) + integer(len(target))
    write("v1-to-v3.patch", header + control + delta + extra)
    invoke("manifest", "create", "installed.bin", "v3.bin", "v1-to-v3.patch", "v1-to-v3.json")


def identity(data):
    return {"size_bytes": str(len(data)), "sha256": hashlib.sha256(data).hexdigest()}


def expect(label, observed, expected):
    if observed != expected:
        raise RuntimeError(f"{label}: expected {expected!r}, got {observed!r}")


def run_cli(cli, directory, label, *args):
    try:
        result = subprocess.run([cli, *args], cwd=directory, capture_output=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RuntimeError(f"{label}: {' '.join(args)}: {error}") from error
    if result.returncode:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"{label}: {' '.join(args)} exited {result.returncode}: {detail}")
    return result.stdout


def read_plan(label, stdout, expected):
    try:
        plan = json.loads(stdout)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise RuntimeError(f"{label}: invalid CLI JSON: {error}") from error
    expect(label, plan, expected)
    return plan


def patch_step(directory, manifest_path, patch_path):
    record = json.loads((directory / manifest_path).read_bytes())
    patch = identity((directory / patch_path).read_bytes())
    expect(f"fixture identity for {patch_path}", patch, record["patch"])
    return {
        "manifest_path": manifest_path,
        "old": record["old"],
        "new": record["new"],
        "patch": patch,
    }


def run_demo(cli, directory):
    def write(name, data):
        (directory / name).write_bytes(data)

    def prepare(*args):
        run_cli(cli, directory, "prepare demo fixture", *args)

    start, _, target = prepare_two_hop(write, prepare)
    prepare_direct(write, prepare, target)
    expected_target = {"size_bytes": "2048", "sha256": TARGET_SHA256}
    expect("independent target identity", identity(target), expected_target)

    first = patch_step(directory, "v1-to-v2.json", "v1-to-v2.patch")
    second = patch_step(directory, "v2-to-v3.json", "v2-to-v3.patch")
    direct = patch_step(directory, "v1-to-v3.json", "v1-to-v3.patch")
    expect("fixture patch sizes", [edge["patch"]["size_bytes"] for edge in (first, second, direct)],
           ["204", "155", "2532"])
    marker = second["manifest_path"]
    candidates = ("--target-manifest", marker, "--", "installed.bin",
                  first["manifest_path"], marker, direct["manifest_path"])
    common = {"schema_version": 1, "start": identity(start), "target": expected_target}

    label = "one-hop plan"
    raw = run_cli(cli, directory, label,
                  "manifest", "plan", "--allow-full", "--max-steps", "1", *candidates)
    one_hop = read_plan(label, raw, {**common, "strategy": "full-file", "download_bytes": "2048"})
    print(f"1. At most one hop: {one_hop['strategy']}, download {one_hop['download_bytes']} bytes "
          f"(direct patch: {direct['patch']['size_bytes']} bytes).")

    label = "two-hop plan"
    raw = run_cli(cli, directory, label,
                  "manifest", "plan", "--allow-full", "--max-steps", "2", *candidates)
    two_hop = read_plan(label, raw, {
        **common, "strategy": "patches", "download_bytes": "359", "steps": [first, second],
    })
    patch_sizes = [step["patch"]["size_bytes"] for step in two_hop["steps"]]
    print(f"2. At most two hops: {two_hop['strategy']}, download "
          f"{' + '.join(patch_sizes)} = {two_hop['download_bytes']} bytes.")

    (directory / "v1-to-v2.patch").rename(directory / "first.bin")
    (directory / "v2-to-v3.patch").rename(directory / "second.bin")
    label = "offline plan"
    raw = run_cli(cli, directory, label, "manifest", "plan-local",
                  "--local-patch", "second.bin", "--local-patch", "first.bin", *candidates)
    offline = read_plan(label, raw, {
        **common,
        "total_patch_bytes": "359",
        "download_bytes": "0",
        "steps": [{**first, "patch_path": "first.bin"}, {**second, "patch_path": "second.bin"}],
    })
    chain_args = []
    ordered_patches = []
    for step in offline["steps"]:
        chain_args.extend((step["patch_path"], step["manifest_path"]))
        ordered_patches.append(step["patch_path"])
    print(f"3. Local route: {' -> '.join(ordered_patches)}, "
          f"{offline['total_patch_bytes']} patch bytes on disk, download {offline['download_bytes']} bytes.")

    run_cli(cli, directory, "restore offline route", "patch-chain", "--target-manifest", marker,
            "--", "installed.bin", "restored.bin", *chain_args)
    restored_path = directory / "restored.bin"
    if not restored_path.is_file():
        raise RuntimeError("restore offline route: CLI returned success without restored.bin")
    restored = restored_path.read_bytes()
    expect("restored identity", identity(restored), expected_target)
    expect("independent v3.bin is unchanged", (directory / "v3.bin").read_bytes() == target, True)
    expect("restored.bin equals v3.bin byte for byte", restored == target, True)
    print(f"4. restored.bin equals v3.bin byte for byte ({len(restored)} bytes).")
    print(f"SHA-256: {TARGET_SHA256}")
    print("UPDATE DEMO PASS")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, required=True)
    args = parser.parse_args()
    cli = args.cli.resolve()
    if not cli.is_file():
        parser.error(f"MoonBSDiff executable not found: {cli}")
    try:
        directory = Path(tempfile.mkdtemp(prefix="moonbsdiff-update-demo-"))
        print(f"Demo files: {directory}", flush=True)
        run_demo(cli, directory)
    except (OSError, RuntimeError, ValueError) as error:
        print(f"Update demo failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
