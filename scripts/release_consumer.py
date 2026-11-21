"""External candidate or registry consumer with a fresh SDK registry and project."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import urllib.request
import zipfile

from release_audit import audit_zip, require, sha


ROOT = Path(__file__).resolve().parents[1]
MODULE = "BigSaltyMan/moonbsdiff"
COMMON_MARKER = "restored bytes equal predefined new bytes: PASS"
PROBES = {
    "0.1.0": "cmd/example/main.mbt",
    "0.2.0": "cmd/example/main.mbt",
    "0.4.0": "scripts/release_consumer.mbt.in",
    "0.5.0": "scripts/release_consumer_050.mbt.in",
    "0.5.1": "scripts/release_consumer_050.mbt.in",
    "0.5.2": "scripts/release_consumer_050.mbt.in",
    "0.5.3": "scripts/release_consumer_050.mbt.in",
}
MANIFEST_PROBE_PATCH_CAPS = {"0.5.0": 65536, "0.5.1": 131072, "0.5.2": 131072, "0.5.3": 131072}
MANIFEST_PROBE_PACKAGE = """import {
  "BigSaltyMan/moonbsdiff",
  "BigSaltyMan/moonbsdiff/manifest",
}

pkgtype(kind: "executable")
supported_targets = "-all+native+js+wasm-gc"
"""


def verify_module(dependency, version):
    text = (dependency / "moon.mod").read_text(encoding="utf8")
    for field, expected in (("name", MODULE), ("version", version)):
        actual = re.search(rf'^{field}\s*=\s*"([^"\r\n]+)"', text, re.M)
        require(actual is not None and actual[1] == expected,
                f"dependency {field} is not {expected}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path)
    parser.add_argument("--audit", required=True, type=Path)
    parser.add_argument("--targets", nargs="+", choices=["native", "js", "wasm-gc"],
                        default=["js", "wasm-gc"])
    args = parser.parse_args()
    audit = json.loads(args.audit.read_text(encoding="utf8"))
    target_version = audit.get("version")
    require(isinstance(target_version, str) and target_version in PROBES,
            "audit version missing or unsupported; no consumer probe selected")
    require(audit.get("module") == MODULE, "audit names another module")
    probe_path = PROBES[target_version]
    probe = (ROOT / probe_path).read_bytes()
    patch_cap = MANIFEST_PROBE_PATCH_CAPS.get(target_version)
    expected_marker = f"manifest {target_version} probe: candidate=1 " if patch_cap is not None else None
    if patch_cap is not None:
        require(b"@manifest.plan_update" in probe and b"@manifest.diff" in probe,
                f"{target_version} consumer template must exercise the manifest subpackage")
        probe += (
            f'\n///|\nconst RELEASE_VERSION : String = "{target_version}"\n'
            f'\n///|\nconst RELEASE_APPLY_PATCH_CAP : Int64 = {patch_cap}L\n'
        ).encode("utf8")

    folder = Path(tempfile.mkdtemp(prefix="moonbsdiff-consumer-"))
    sdk = folder / "sdk"
    sdk.mkdir()
    original = (Path(os.environ["MOON_HOME"]).resolve() if os.environ.get("MOON_HOME")
                else Path(shutil.which("moon")).resolve().parent.parent)
    for name in ["bin", "include", "lib", "share"]:
        shutil.copytree(original / name, sdk / name)
    env = dict(os.environ, MOON_HOME=str(sdk), PATH=str(sdk / "bin") + os.pathsep + os.environ["PATH"])
    project = folder / "consumer"
    project.mkdir()
    commands = []

    def run(command):
        result = subprocess.run(command, cwd=project, env=env, capture_output=True, timeout=240)
        (folder / f"command-{len(commands)}.log").write_bytes(result.stdout + result.stderr)
        commands.append(dict(command=command, exit_code=result.returncode))
        require(result.returncode == 0, f"consumer command failed: {command}; logs {folder}")
        return result.stdout.decode("utf8")

    toolchain = run(["moon", "version", "--all"])
    require("moonc v0.10.19+bee578715" in toolchain, "wrong consumer compiler")
    module = project / "moon.mod"
    module.write_text('name = "releasecheck/consumer"\nversion = "0.1.0"\n', encoding="utf8")
    if expected_marker:
        (project / "moon.pkg").write_text(MANIFEST_PROBE_PACKAGE, encoding="utf8")
    else:
        (project / "moon.pkg").write_bytes((ROOT / "cmd/example/moon.pkg").read_bytes())
    (project / "main.mbt").write_bytes(probe)

    mode = "candidate" if args.candidate else "registry"
    package_url = None
    if args.candidate:
        package = args.candidate.read_bytes()
        require(sha(package) == audit["package_sha256"], "candidate ZIP differs from its audit")
        members = audit_zip(args.candidate, audit["files"])
        dependency = folder / "candidate"
        dependency.mkdir()
        with zipfile.ZipFile(args.candidate) as archive:
            archive.extractall(dependency)
        verify_module(dependency, target_version)
        (folder / "moon.work").write_text('members = ["candidate", "consumer"]\n', encoding="utf8")
        with module.open("a", encoding="utf8") as out:
            out.write(f'import {{ "{MODULE}@{target_version}" }}\n')
        run(["moon", "update"])
    else:
        require(not (folder / "moon.work").exists(), "registry workspace override")
        run(["moon", "update"])
        run(["moon", "add", f"{MODULE}@{target_version}"])
        metadata_url = f"https://mooncakes.io/api/v0/manifest/{MODULE}/{target_version}"
        with urllib.request.urlopen(metadata_url, timeout=60) as response:
            metadata = json.load(response)
        require(metadata["version"] == target_version and not metadata["yanked"],
                "registry returned another version")
        package_url = f"https://download.mooncakes.io/user/{MODULE}/{target_version}.zip"
        with urllib.request.urlopen(package_url, timeout=60) as response:
            package = response.read()
        downloaded = folder / "registry.zip"
        downloaded.write_bytes(package)
        members = audit_zip(downloaded, audit["files"])
        require(metadata["metadata"]["checksum"] == sha(package), "registry checksum differs")
        dependency = project / ".mooncakes" / MODULE
        require(dependency.is_dir(), "installed registry dependency missing")
        verify_module(dependency, target_version)
        for name, digest in audit["files"].items():
            installed = dependency / name
            require(installed.is_file() and sha(installed.read_bytes()) == digest,
                    "installed registry bytes differ: " + name)

    observations = {}
    for target in args.targets:
        # Scope check/build to the consumer package (`.`), matching `moon run .`
        # and real `.mooncakes` dependency behavior so candidate `moon.work`
        # overrides do not typecheck stripped `for "test"` blocks in the library.
        run(["moon", "check", ".", "--target", target, "--deny-warn"])
        run(["moon", "build", ".", "--target", target])
        output = run(["moon", "run", ".", "--target", target])
        lines = output.splitlines()
        require(COMMON_MARKER in lines, "consumer success marker missing")
        if expected_marker:
            lines = [line for line in lines if line.startswith(expected_marker)]
            require(len(lines) == 1 and lines[0].endswith(f" apply_patch_cap={patch_cap}"),
                    f"{target} did not run the {target_version} manifest and default limit probe")
        observations[target] = lines

    tree = run(["moon", "tree"])
    require(f"{MODULE}@{target_version}" in tree, "resolver tree does not show the audited version")
    if mode == "registry":
        require(not (folder / "moon.work").exists(), "registry workspace override after install")
    report = dict(
        schema=1, mode=mode, source_sha=audit["source_sha"], version=target_version,
        package_sha256=sha(package), package_size=len(package), candidate_sha256=audit["package_sha256"],
        members=members, member_bytes_equal=True, package_url=package_url, targets=args.targets,
        byte_equal=True, probe=probe_path, manifest_probe=bool(expected_marker),
        observations=observations, dependency_tree=tree, commands=commands,
        toolchain="\n".join(line.split(" /")[0] for line in toolchain.splitlines()
                            if line and not line.startswith("Feature flags")),
    )
    report_path = folder / "consumer.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf8")
    print("CONSUMER PASS " + json.dumps(dict(
        report=str(report_path), mode=mode, version=target_version, probe=probe_path,
        targets=args.targets, package_sha256=sha(package), observations=observations,
    )))


if __name__ == "__main__":
    main()
