"""Audit a package built from git archive, never from uncommitted worktree files."""

import argparse
import hashlib
import io
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]

FORBIDDEN_PACKAGE_PREFIXES = (
    "testdata/",
    "scripts/",
    "tools/",
    "docs/",
    "examples/",
    "cmd/",
)
FORBIDDEN_PACKAGE_SUFFIXES = (
    "_test.mbt",
    "_wbtest.mbt",
)
ALLOWED_ROOT_METADATA = frozenset({
    "moon.mod",
    "README.md",
    "README.zh-CN.md",
    "LICENSE",
    "CHANGELOG.md",
})
ALLOWED_LIBRARY_PACKAGES = frozenset({
    "",
    "manifest",
    "internal/manifest",
    "internal/bzip2",
})
ALLOWED_BZIP2_PROVENANCE = frozenset({
    "LICENSE",
    "README.md",
    "source-lock.json",
    "changes.patch",
    "encoder-changes.patch",
})
REQUIRED_PACKAGE_MEMBERS = (
    "LICENSE",
    "README.md",
    "README.zh-CN.md",
    "CHANGELOG.md",
    "moon.mod",
    "moon.pkg",
    "pkg.generated.mbti",
    "apply_stream.mbt",
    "manifest/moon.pkg",
    "manifest/pkg.generated.mbti",
    "manifest/bundle.mbt",
    "manifest/bundle_index.mbt",
    "manifest/manifest.mbt",
    "manifest/parse.mbt",
    "manifest/plan.mbt",
    "manifest/restore.mbt",
    "manifest/signature.mbt",
    "internal/manifest/moon.pkg",
    "internal/manifest/pkg.generated.mbti",
    "internal/manifest/hash.mbt",
    "internal/manifest/serialize.mbt",
    "internal/manifest/version.mbt",
    "internal/bzip2/moon.pkg",
    "internal/bzip2/pkg.generated.mbti",
    "internal/bzip2/LICENSE",
    "internal/bzip2/README.md",
    "internal/bzip2/source-lock.json",
    "internal/bzip2/changes.patch",
    "internal/bzip2/encoder-changes.patch",
    "internal/bzip2/writer.mbt",
    "internal/bzip2/encode.mbt",
    "internal/bzip2/bwt.mbt",
    "internal/bzip2/sink.mbt",
)
REQUIRED_SOURCE_ARCHIVE_MEMBERS = (
    ".moonignore",
    "tools/oracle/BSDIFF-LICENSE.txt",
    "tools/oracle/BZIP2-LICENSE.txt",
    "docs/acceptance.md",
    "docs/update-demo.md",
    "cmd/main/moon.pkg",
    "cmd/main/native_io.c",
    "cmd/main/manifest_plan_local.mbt",
    "cmd/main/help.mbt",
    "scripts/release_consumer_050.mbt.in",
    "scripts/run_update_demo.py",
    "scripts/native_test.py",
    "testdata/upstream/seeded-random/old.bin",
    "testdata/upstream/seeded-random/new.bin",
    "testdata/upstream/seeded-random/patch.bin",
)


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def is_safe_member_path(name):
    if not name or name.endswith("/") or "\\" in name:
        return False
    p = pathlib.PurePosixPath(name)
    if p.is_absolute() or ".." in p.parts:
        return False
    return not any(part in ("", ".") for part in p.parts)


def is_excluded_package_member(name):
    p = pathlib.PurePosixPath(name)
    if any(part.startswith(".") for part in p.parts):
        return True
    if name.startswith(FORBIDDEN_PACKAGE_PREFIXES):
        return True
    if name.endswith(FORBIDDEN_PACKAGE_SUFFIXES):
        return True
    return False


def is_allowed_package_member(name):
    if not is_safe_member_path(name) or is_excluded_package_member(name):
        return False
    parts = pathlib.PurePosixPath(name).parts
    if len(parts) == 1:
        filename = parts[0]
        return (
            filename in ALLOWED_ROOT_METADATA
            or filename in ("moon.pkg", "pkg.generated.mbti")
            or filename.endswith(".mbt")
        )
    pkg_dir = "/".join(parts[:-1])
    filename = parts[-1]
    if pkg_dir not in ALLOWED_LIBRARY_PACKAGES:
        return False
    if pkg_dir == "internal/bzip2" and filename in ALLOWED_BZIP2_PROVENANCE:
        return True
    return filename in ("moon.pkg", "pkg.generated.mbti") or filename.endswith(".mbt")


def expected_package_files(source_archive_files):
    return {
        name: digest
        for name, digest in source_archive_files.items()
        if not is_excluded_package_member(name)
    }


def audit_source_archive(source_archive_names, required=REQUIRED_SOURCE_ARCHIVE_MEMBERS):
    present = set(source_archive_names)
    for name in required:
        require(name in present, "missing required source archive member: " + name)


def audit_package_policy(names, required=REQUIRED_PACKAGE_MEMBERS):
    name_list = list(names)
    require(len(name_list) == len(set(name_list)), "duplicate archive member")
    for name in name_list:
        require(is_safe_member_path(name), "unsafe member path: " + name)
        require(
            not name.startswith(FORBIDDEN_PACKAGE_PREFIXES),
            "forbidden directory in package: " + name,
        )
        require(
            not name.endswith(FORBIDDEN_PACKAGE_SUFFIXES),
            "forbidden test file in package: " + name,
        )
        require(
            is_allowed_package_member(name),
            "unexpected non-library package member: " + name,
        )
    present = set(name_list)
    for name in required:
        require(name in present, "missing required package member: " + name)


def audit_zip(path, expected):
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        require(len(names) == len(set(names)), "duplicate archive member")
        require(z.testzip() is None, "bad ZIP CRC")
        for name in names:
            require(is_safe_member_path(name), "unsafe member path")
        require(set(names) == set(expected), "missing/extra package members")
        for name in names:
            require(sha(z.read(name)) == expected[name], "changed package member: " + name)
    return len(names)


def audit_release_package(package_path, source_archive_files):
    """Two-layer audit: clean-source byte fidelity + library package member policy."""
    audit_source_archive(source_archive_files)
    package_expected = expected_package_files(source_archive_files)
    audit_package_policy(package_expected)
    with zipfile.ZipFile(package_path) as z:
        actual_names = z.namelist()
    audit_package_policy(actual_names)
    count = audit_zip(package_path, package_expected)
    return count, package_expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", default="HEAD")
    args = parser.parse_args()
    git = ["git", "-c", "safe.directory=" + ROOT.as_posix()]
    revision = subprocess.check_output(git + ["rev-parse", args.revision], cwd=ROOT, text=True).strip()
    raw = subprocess.check_output(git + ["archive", "--format=zip", revision], cwd=ROOT)
    folder = pathlib.Path(tempfile.mkdtemp(prefix="moonbsdiff-release-audit-"))
    source = folder / "source"
    source.mkdir()
    with zipfile.ZipFile(io.BytesIO(raw)) as z:
        z.extractall(source)
        archive_all = {
            name: sha(z.read(name))
            for name in z.namelist()
            if not name.endswith("/")
        }
    commands = []

    def run(command):
        r = subprocess.run(command, cwd=source, capture_output=True, timeout=180)
        commands.append(dict(command=command, exit_code=r.returncode))
        (folder / ("command-" + str(len(commands)) + ".log")).write_bytes(r.stdout + r.stderr)
        require(r.returncode == 0, "command failed: " + str(command) + "; logs in " + str(folder))
        return r.stdout.decode("utf8")

    version = run(["moon", "version", "--all"])
    require(
        "moon 0.1.20261102 (ea07287 2026-11-02)" in version
        and "moonc v0.10.19+bee578715" in version,
        "wrong release toolchain",
    )
    run(["moon", "update"])
    run(["moon", "fmt", "--check"])
    run(["moon", "info"])
    for name, digest in archive_all.items():
        require(sha((source / name).read_bytes()) == digest, "source changed during preparation: " + name)
    run(["moon", "package", "--list"])
    module_version = re.search(
        r'^version\s*=\s*"([^"]+)"',
        (source / "moon.mod").read_text(encoding="utf8"),
        re.M,
    )[1]
    package = source / ("_build/publish/BigSaltyMan-moonbsdiff-" + module_version + ".zip")
    count, package_files = audit_release_package(package, archive_all)
    run([sys.executable, "scripts/check_compression.py", "--encoder-source"])

    dependencies = {}
    for p in sorted((source / ".mooncakes").glob("*/*/moon.mod")):
        text = p.read_text(encoding="utf8")
        name = re.search(r'^name\s*=\s*"([^"]+)"', text, re.M)[1]
        version_dep = re.search(r'^version\s*=\s*"([^"]+)"', text, re.M)[1]
        license_path = p.parent / "LICENSE"
        require(license_path.is_file(), "dependency license missing")
        dependencies[name] = dict(
            version=version_dep,
            manifest_sha256=sha(p.read_bytes()),
            license_sha256=sha(license_path.read_bytes()),
        )
    require(dependencies["moonbitstack/moonzip"]["version"] == "0.3.5", "wrong compression version")
    report = dict(
        schema=1,
        source_sha=revision,
        module="BigSaltyMan/moonbsdiff",
        version=module_version,
        archive_sha256=sha(raw),
        package_sha256=sha(package.read_bytes()),
        package_size=package.stat().st_size,
        members=count,
        source_members=len(archive_all),
        files=package_files,
        dependencies=dependencies,
        toolchain="\n".join(
            line.split(" /")[0]
            for line in version.splitlines()
            if line and not line.startswith("Feature flags")
        ),
        commands=commands,
        source_directory=str(source),
        package_path=str(package),
    )
    (folder / "audit.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf8")
    print(
        "RELEASE AUDIT "
        + json.dumps(
            dict(
                report=str(folder / "audit.json"),
                source_sha=revision,
                package_sha256=report["package_sha256"],
                members=count,
            )
        )
    )


if __name__ == "__main__":
    main()
