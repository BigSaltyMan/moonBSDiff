"""Offline verification by default; --generate invokes the real locked oracle."""
import argparse
import hashlib
import json
import pathlib
import random
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
DATA = ROOT / "testdata/upstream"
LOCK = ROOT / "tools/oracle/upstream.lock.json"

def sha(data):
    return hashlib.sha256(data).hexdigest()

def inputs():
    base = b"0123456789abcdefghij"
    rng = random.Random(20261106)
    random_old = rng.randbytes(2048)
    return [
        ("both-empty", b"", b"", "empty literals"),
        ("old-empty", b"", b"new\x00\xff", "empty to binary literal"),
        ("new-empty", base, b"", "literal to empty"),
        ("identical", base, base, "same literal"),
        ("replace", base, base[:6]+b"XYZ"+base[9:], "replace bytes 6..8"),
        ("insert", base, base[:6]+b"insert"+base[6:], "insert at offset 6"),
        ("delete", base, base[:6]+base[9:], "delete bytes 6..8"),
        ("prepend", base, b"prefix"+base, "prepend literal"),
        ("append", base, base+b"suffix", "append literal"),
        ("all-bytes", bytes(range(256)), bytes(reversed(range(256)))+b"\x00\xff", "all byte values reversed, then 00 ff"),
        ("periodic", b"abc\x00\xff"*300, b"abc\x00\xff"*140+b"X"+b"abc\x00\xff"*160, "periodic literal with insertion"),
        ("block-move", b"A"*400+b"B"*400+b"C"*400, b"C"*400+b"A"*400+b"B"*400, "move final block to front"),
        ("seeded-random", random_old, random_old[:700]+rng.randbytes(31)+random_old[731:], "Python random.Random(20261106), randbytes(2048), replace [700:731] with next randbytes(31)"),
    ]

def run_output(args, output, timeout=15):
    subprocess.run([str(a) for a in args], check=True, timeout=timeout, capture_output=True)
    if not output.is_file():
        raise ValueError("missing subprocess output: " + str(output))
    return output.read_bytes()

def compare(actual, expected):
    if actual != expected:
        raise ValueError("restored bytes differ from original new bytes")

def verify(directory=DATA):
    manifest = json.loads((directory/"manifest.json").read_text())
    assert manifest["schema_version"] == 1
    assert manifest["reference"] == {"version": "4.3", "lock_sha256": sha(LOCK.read_bytes())}
    cases = inputs()
    assert [row["id"] for row in manifest["cases"]] == [c[0] for c in cases], "case set mismatch"
    for row, (name, old, new, method) in zip(manifest["cases"], cases):
        assert row["method"] == method
        for kind, expected in [("old",old),("new",new),("patch",None)]:
            record = row[kind]
            assert record["path"] == f"{name}/{kind}.bin"
            raw = (directory/record["path"]).read_bytes()
            assert record["size"] == len(raw) and record["sha256"] == sha(raw), record["path"]
            if expected is not None:
                compare(raw, expected)
    print(f"{len(cases)} offline cases verified")
    return manifest

def generate():
    report = json.loads((ROOT/"_build/oracle/build.json").read_text())
    assert report["lock_sha256"] == sha(LOCK.read_bytes())
    for name, digest in report["products"].items():
        assert sha((ROOT/"_build/oracle"/name).read_bytes()) == digest
    bsdiff = ROOT/"_build/oracle/bsdiff"
    bspatch = ROOT/"_build/oracle/bspatch"
    with tempfile.TemporaryDirectory() as temp:
        work = pathlib.Path(temp)
        rows = []
        for name, old, new, method in inputs():
            folder = work/name
            folder.mkdir()
            (folder/"old.bin").write_bytes(old)
            (folder/"new.bin").write_bytes(new)
            run_output([bsdiff, folder/"old.bin", folder/"new.bin", folder/"patch.bin"], folder/"patch.bin")
            restored = run_output([bspatch, folder/"old.bin", folder/"restored.bin", folder/"patch.bin"], folder/"restored.bin")
            compare(restored, new)
            (folder/"restored.bin").unlink()
            row = {"id":name, "method":method}
            for kind in ["old","new","patch"]:
                raw = (folder/(kind+".bin")).read_bytes()
                row[kind] = {"path": f"{name}/{kind}.bin", "size": len(raw), "sha256": sha(raw)}
            rows.append(row)
        manifest = {"schema_version":1, "reference":{"version":"4.3", "lock_sha256":sha(LOCK.read_bytes())}, "cases":rows}
        (work/"manifest.json").write_text(json.dumps(manifest,indent=2)+"\n")
        verify(work)
        if (DATA/"manifest.json").exists():
            existing = verify(DATA)
            if manifest != existing:
                raise ValueError("regeneration differs: investigate before replacing fixed data")
            for row in rows:
                for kind in ["old","new","patch"]:
                    path = row[kind]["path"]
                    compare((work/path).read_bytes(), (DATA/path).read_bytes())
            print("regeneration exactly matches fixed data")
        else:
            DATA.mkdir(parents=True,exist_ok=True)
            for path in work.rglob("*"):
                if path.is_file():
                    target = DATA/path.relative_to(work)
                    target.parent.mkdir(parents=True,exist_ok=True)
                    shutil.copyfile(path,target)
        print(f"{len(rows)} real bsdiff -> bspatch byte comparisons passed")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--generate", action="store_true")
    args = parser.parse_args()
    if args.generate:
        generate()
    else:
        verify()
