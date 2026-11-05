import bz2, json, pathlib, subprocess, sys
root = pathlib.Path(__file__).resolve().parent
target = sys.argv[1] if len(sys.argv) > 1 else "native"
work = pathlib.Path("_build/dependency-probe")
(work / "cmd/main").mkdir(parents=True, exist_ok=True)
(work / "moon.mod").write_text('name = "probe/bzip2"\nversion = "0.1.0"\nimport {\n "moonbitstack/moonzip@0.3.5",\n "moonbitstack/moonbase@0.4.2",\n}\n')
(work / "cmd/main/moon.pkg").write_text('import {\n "moonbitstack/moonzip/bzip2",\n "moonbitstack/moonbase/base16",\n}\npkgtype(kind: "executable")\n')
(work / "cmd/main/main.mbt").write_bytes((root / "main.mbt").read_bytes())
result = subprocess.run(["moon", "run", "cmd/main", "--target", target], cwd=work, check=True, capture_output=True, text=True)
expected = {v["name"]: bytes(v["data"]) for v in json.loads((root / "vectors.json").read_text(encoding="utf-8"))}
rows = dict(line.split(":", 1) for line in result.stdout.splitlines())
assert rows.keys() == expected.keys() and len(rows) == 6
for name, value in rows.items():
    assert bz2.decompress(bytes.fromhex(value)) == expected[name], name
print(f"{target}: {len(rows)} vectors passed in both directions (level 1)")
