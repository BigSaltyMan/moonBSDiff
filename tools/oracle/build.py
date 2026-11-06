"""Build the locked, unmodified BSDiff oracle on Linux (test tools only)."""
import hashlib
import json
import pathlib
import platform
import subprocess
import tarfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
CACHE = ROOT / "_build/oracle"
LOCK_PATH = ROOT / "tools/oracle/upstream.lock.json"

def digest(data):
    return hashlib.sha256(data).hexdigest()

def run(args, **kwargs):
    return subprocess.run(args, cwd=ROOT, check=True, timeout=120, capture_output=True, text=True, **kwargs).stdout.strip()

def archive(spec):
    path = CACHE / spec["archive"]
    if path.exists():
        data = path.read_bytes()
        if len(data) != spec["size"] or digest(data) != spec["sha256"]:
            raise ValueError("cached archive integrity failure: " + str(path))
        return path, "reverified cache"
    errors = []
    for url in spec["urls"]:
        try:
            data = urllib.request.urlopen(url, timeout=30).read()
        except Exception as exc:
            errors.append(f"{url}: {exc}")
            continue
        if len(data) != spec["size"] or digest(data) != spec["sha256"]:
            raise ValueError("download integrity failure: " + url)
        path.write_bytes(data)
        return path, url
    raise RuntimeError("all sources failed: " + "; ".join(errors))

def main():
    if platform.system() != "Linux":
        raise RuntimeError("This build recipe is verified on Linux only; use WSL on Windows")
    CACHE.mkdir(parents=True, exist_ok=True)
    lock = json.loads(LOCK_PATH.read_text())
    sources = {}
    for name in ["bsdiff", "bzip2"]:
        spec = lock[name]
        path, origin = archive(spec)
        with tarfile.open(path) as tar:
            tar.extractall(CACHE, filter="data")
        sources[name] = origin
    src = CACHE / "bsdiff-4.3"
    for name, expected in lock["bsdiff"]["files"].items():
        if digest((src / name).read_bytes()) != expected:
            raise ValueError("source mismatch: " + name)
    bz = CACHE / "bzip2-1.0.8"
    commands = [["make", "-C", "_build/oracle/bzip2-1.0.8", "-B", "libbz2.a", "CC=gcc", "CFLAGS=-O2 -Wall -D_FILE_OFFSET_BITS=64"]]
    run(commands[0])
    for tool in ["bsdiff", "bspatch"]:
        command = [lock["compiler"], *lock["cflags"], "-I_build/oracle/bzip2-1.0.8", f"_build/oracle/bsdiff-4.3/{tool}.c", "_build/oracle/bzip2-1.0.8/libbz2.a", "-o", f"_build/oracle/{tool}"]
        run(command)
        commands.append(command)
    (CACHE / "bzversion.c").write_text('#include <stdio.h>\n#include "bzlib.h"\nint main(void){puts(BZ2_bzlibVersion());return 0;}\n')
    run(["gcc", "-I" + str(bz), str(CACHE / "bzversion.c"), str(bz / "libbz2.a"), "-o", str(CACHE / "bzversion")])
    report = {"schema_version": 1, "lock_sha256": digest(LOCK_PATH.read_bytes()), "os": platform.platform(), "architecture": platform.machine(), "compiler": run(["gcc", "--version"]), "bzip2_library_sha256": digest((bz/"libbz2.a").read_bytes()), "bzip2_runtime": run([str(CACHE / "bzversion")]), "sources": sources, "commands": commands, "adaptations": [], "products": {n: digest((CACHE/n).read_bytes()) for n in ["bsdiff", "bspatch"]}}
    (CACHE / "build.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))

if __name__ == "__main__":
    main()
