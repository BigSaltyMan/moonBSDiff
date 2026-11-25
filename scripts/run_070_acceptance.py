"""End-to-end 0.7.0 acceptance demonstration across all four MoonBSDiff pillars."""

from __future__ import annotations

import argparse
import bz2
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def lcg_bytes(seed: int, length: int) -> bytes:
    state = seed & 0xFFFFFFFF
    out = bytearray(length)
    for i in range(length):
        state = (state * 1664525 + 1013904223) & 0xFFFFFFFF
        out[i] = (state >> 24) & 0xFF
    return bytes(out)


def bsdiff_int(value: int) -> bytes:
    if value < 0:
        mag = (-value) | (1 << 63)
        return mag.to_bytes(8, "little")
    return value.to_bytes(8, "little")


def build_bsdiff_patch(
    triples: list[tuple[int, int, int]],
    diff_bytes: bytes,
    extra_bytes: bytes,
    new_size: int,
) -> bytes:
    ctrl_raw = b"".join(bsdiff_int(v) for triple in triples for v in triple)
    ctrl_bz2 = bz2.compress(ctrl_raw)
    diff_bz2 = bz2.compress(diff_bytes)
    extra_bz2 = bz2.compress(extra_bytes)
    header = (
        b"BSDIFF40"
        + bsdiff_int(len(ctrl_bz2))
        + bsdiff_int(len(diff_bz2))
        + bsdiff_int(new_size)
    )
    return header + ctrl_bz2 + diff_bz2 + extra_bz2


def canonical_tree_sha256(files: dict[str, bytes]) -> str:
    if not files:
        return sha256_hex(b"")
    lines = [
        f"{sha256_hex(data)} {len(data)} {rel}\n"
        for rel, data in sorted(files.items(), key=lambda kv: kv[0].encode("utf-8"))
    ]
    return sha256_hex("".join(lines).encode("utf-8"))


def write_tree(root: Path, files: dict[str, bytes]) -> None:
    root.mkdir(parents=True, exist_ok=True)
    for rel, data in files.items():
        target = root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)


def read_tree(root: Path) -> dict[str, bytes]:
    out: dict[str, bytes] = {}
    for path in sorted(root.rglob("*")):
        if path.is_file():
            out[path.relative_to(root).as_posix()] = path.read_bytes()
    return out


def expect(label: str, actual, expected) -> None:
    if actual != expected:
        raise RuntimeError(f"{label}: expected {expected!r}, got {actual!r}")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def run_cli(
    cli: Path,
    cwd: Path,
    label: str,
    args: list[str | Path],
    expected_code: int = 0,
) -> subprocess.CompletedProcess[bytes]:
    str_args = [str(a) for a in args]
    try:
        proc = subprocess.run(
            [str(cli), *str_args],
            cwd=cwd,
            capture_output=True,
            timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired) as err:
        raise RuntimeError(f"{label}: {' '.join(str_args)}: {err}") from err

    if proc.returncode != expected_code:
        stderr_txt = proc.stderr.decode("utf-8", errors="replace").strip()
        stdout_txt = proc.stdout.decode("utf-8", errors="replace").strip()
        raise RuntimeError(
            f"{label}: expected exit {expected_code}, got {proc.returncode}\n"
            f"  cmd: {' '.join(str_args)}\n"
            f"  stdout: {stdout_txt}\n"
            f"  stderr: {stderr_txt}"
        )
    if expected_code != 0:
        require(
            proc.stdout == b"",
            f"{label}: failed command emitted non-empty stdout: {proc.stdout!r}",
        )
        require(bool(proc.stderr), f"{label}: failed command emitted empty stderr")
    else:
        require(
            proc.stderr == b"",
            f"{label}: succeeded with unexpected stderr: {proc.stderr!r}",
        )
    return proc


def run_json(cli: Path, cwd: Path, label: str, args: list[str | Path]) -> dict:
    proc = run_cli(cli, cwd, label, args, expected_code=0)
    try:
        return json.loads(proc.stdout.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as err:
        raise RuntimeError(f"{label}: invalid JSON output: {err}") from err


def make_catalog_bytes(
    channel: str,
    catalog_version: int,
    min_version: int,
    releases: list[dict],
    patches: list[dict],
) -> bytes:
    doc = {
        "schema": 1,
        "type": "moonbsdiff-release-catalog",
        "channel": channel,
        "catalog_version": catalog_version,
        "min_version": min_version,
        "releases": releases,
        "patches": patches,
    }
    return (json.dumps(doc, separators=(",", ":")) + "\n").encode("utf-8")


def pillar_patch_forensics(cli: Path, work: Path) -> str:
    sec = work / "pillar_forensics"
    sec.mkdir()

    # 1. Healthy patch: low risk, exact required_limits round-trip.
    old_data = lcg_bytes(0x70010001, 4096)
    new_data = old_data[:1800] + b"MOONBSDIFF-070-HEALTHY!!" + old_data[1824:]
    old_path = sec / "old.bin"
    new_path = sec / "new.bin"
    healthy_patch = sec / "healthy.patch"
    old_path.write_bytes(old_data)
    new_path.write_bytes(new_data)
    run_cli(cli, sec, "forensics diff", ["diff", old_path, new_path, healthy_patch])

    healthy = run_json(
        cli, sec, "forensics healthy analyze", ["inspect", "--analyze", "--json", healthy_patch]
    )
    expect("healthy validation", healthy["validation"], "analyze")
    expect("healthy risk_level", healthy["risk_level"], "low")
    expect("healthy risk_flags", healthy["risk_flags"], [])
    req = healthy["required_limits"]
    rechecked = run_json(
        cli,
        sec,
        "forensics required_limits roundtrip",
        [
            "inspect",
            "--analyze",
            "--json",
            "--max-patch-bytes",
            req["max_patch_bytes"],
            "--max-output-bytes",
            req["max_output_bytes"],
            "--max-expanded-bytes",
            req["max_decompressed_bytes"],
            "--max-controls",
            req["max_control_instructions"],
            healthy_patch,
        ],
    )
    expect("healthy roundtrip parity", rechecked, healthy)

    # 2. Crafted decompression bomb: 128 KiB all-zero diff block compresses to ~100 bytes.
    bomb_output = 131072
    bomb_bytes = build_bsdiff_patch([(bomb_output, 0, 0)], bytes(bomb_output), b"", bomb_output)
    bomb_patch = sec / "bomb.patch"
    bomb_patch.write_bytes(bomb_bytes)

    bomb = run_json(
        cli, sec, "forensics bomb analyze", ["inspect", "--analyze", "--json", bomb_patch]
    )
    expect("bomb risk_level", bomb["risk_level"], "high")
    bomb_flags = {f["code"]: f["severity"] for f in bomb["risk_flags"]}
    expect("bomb HIGH_EXPANSION_RATIO flag", bomb_flags.get("HIGH_EXPANSION_RATIO"), "high")
    ratio = int(bomb["ratios"]["expansion_ratio_permille"])
    require(ratio >= 100_000, f"expected expansion_ratio_permille >= 100000, got {ratio}")
    bomb_req = bomb["required_limits"]
    expect("bomb required max_decompressed_bytes", bomb_req["max_decompressed_bytes"], str(bomb_output + 24))
    expect("bomb required max_control_instructions", bomb_req["max_control_instructions"], "1")

    # 3. Tight-limit bomb preflight fails closed (exit 1, empty stdout).
    tight = run_cli(
        cli,
        sec,
        "forensics tight bomb rejection",
        ["inspect", "--analyze", "--json", "--max-expanded-bytes", "8192", bomb_patch],
        expected_code=1,
    )
    require(
        b"decompressed_remaining" in tight.stderr,
        f"expected decompressed_remaining error, got: {tight.stderr!r}",
    )

    return (
        f"healthy={healthy_patch.stat().st_size}B (risk=low), "
        f"bomb={len(bomb_bytes)}B->{bomb_output + 24}B ({ratio // 1000}x, risk=high, "
        f"HIGH_EXPANSION_RATIO, tight cap rejected)"
    )


def pillar_signed_catalog(cli: Path, work: Path) -> str:
    sec = work / "pillar_catalog"
    sec.mkdir()

    # 1. Keygen Key A and Key B.
    key_a_priv, key_a_pub = sec / "key-a.key", sec / "key-a.pub"
    key_b_priv, key_b_pub = sec / "key-b.key", sec / "key-b.pub"
    meta_a = run_json(cli, sec, "keygen A", ["manifest", "keygen", "--json", key_a_priv, key_a_pub])
    meta_b = run_json(cli, sec, "keygen B", ["manifest", "keygen", "--json", key_b_priv, key_b_pub])
    require(meta_a["key_id"] != meta_b["key_id"], "expected distinct key_ids for Key A and Key B")

    # 2. Build v1 -> v2 -> v3 binaries & real patches.
    v1_bytes = lcg_bytes(0x70020001, 4096)
    v2_bytes = v1_bytes[:1000] + b"CATALOG-V2-PATCH!" + v1_bytes[1017:]
    v3_bytes = v2_bytes[:2500] + b"CATALOG-V3-PATCH!" + v2_bytes[2517:]
    v1, v2, v3 = sec / "v1.bin", sec / "v2.bin", sec / "v3.bin"
    v1.write_bytes(v1_bytes)
    v2.write_bytes(v2_bytes)
    v3.write_bytes(v3_bytes)

    p12, m12 = sec / "v1-to-v2.patch", sec / "v1-to-v2.json"
    p23, m23 = sec / "v2-to-v3.patch", sec / "v2-to-v3.json"
    p13, m13 = sec / "v1-to-v3.patch", sec / "v1-to-v3.json"
    run_cli(cli, sec, "diff v1->v2", ["diff", "--manifest", m12, v1, v2, p12])
    run_cli(cli, sec, "diff v2->v3", ["diff", "--manifest", m23, v2, v3, p23])
    run_cli(cli, sec, "diff v1->v3", ["diff", "--manifest", m13, v1, v3, p13])

    p12_bytes, p23_bytes, p13_bytes = p12.read_bytes(), p23.read_bytes(), p13.read_bytes()
    two_hop_bytes = len(p12_bytes) + len(p23_bytes)
    require(two_hop_bytes < len(v3_bytes), "expected 2-hop patch chain smaller than full v3")

    releases = [
        {"version": 1, "label": "1.0.0", "size_bytes": len(v1_bytes), "sha256": sha256_hex(v1_bytes)},
        {"version": 2, "label": "2.0.0", "size_bytes": len(v2_bytes), "sha256": sha256_hex(v2_bytes)},
        {"version": 3, "label": "3.0.0", "size_bytes": len(v3_bytes), "sha256": sha256_hex(v3_bytes)},
    ]
    patches = [
        {
            "from_version": 1,
            "to_version": 2,
            "patch_size_bytes": len(p12_bytes),
            "patch_sha256": sha256_hex(p12_bytes),
            "manifest_sha256": sha256_hex(m12.read_bytes()),
            "uri": "patches/v1-to-v2.patch",
        },
        {
            "from_version": 2,
            "to_version": 3,
            "patch_size_bytes": len(p23_bytes),
            "patch_sha256": sha256_hex(p23_bytes),
            "manifest_sha256": sha256_hex(m23.read_bytes()),
            "uri": "patches/v2-to-v3.patch",
        },
        {
            "from_version": 1,
            "to_version": 3,
            "patch_size_bytes": 5000,
            "patch_sha256": sha256_hex(p13_bytes),
            "uri": "patches/v1-to-v3.patch",
        },
    ]

    # 3. Sign catalog v1 with Key A, then rotate to catalog v2 (min_version=2) signed with Key B.
    cat_v1 = sec / "catalog-v1.json"
    cat_v2 = sec / "catalog-v2.json"
    sig_a = sec / "catalog-v1.sig"
    sig_b = sec / "catalog-v2.sig"
    cat_v1.write_bytes(make_catalog_bytes("stable", 1, 1, releases, patches))
    cat_v2.write_bytes(make_catalog_bytes("stable", 2, 2, releases, patches))
    run_cli(cli, sec, "sign catalog v1 (Key A)", ["manifest", "catalog", "sign", "--private-key", key_a_priv, cat_v1, sig_a])
    run_cli(cli, sec, "sign catalog v2 (Key B)", ["manifest", "catalog", "sign", "--private-key", key_b_priv, cat_v2, sig_b])

    # 4. Verify BOTH catalogs under overlapping TrustStore [--public-key A --public-key B].
    ver_a = run_json(
        cli,
        sec,
        "verify catalog v1 under [A, B]",
        [
            "manifest", "catalog", "verify",
            "--public-key", key_a_pub, "--public-key", key_b_pub,
            "--signature", sig_a, "--json", cat_v1,
        ],
    )
    ver_b = run_json(
        cli,
        sec,
        "verify catalog v2 under [A, B]",
        [
            "manifest", "catalog", "verify",
            "--public-key", key_a_pub, "--public-key", key_b_pub,
            "--signature", sig_b, "--min-catalog-version", "2", "--json", cat_v2,
        ],
    )
    expect("catalog v1 signer_key_id", ver_a["signer_key_id"], meta_a["key_id"])
    expect("catalog v2 signer_key_id", ver_b["signer_key_id"], meta_b["key_id"])

    # 5. Plan v1 -> v3 with rotated Key B catalog: proves 2-hop savings over 4096 B full target.
    plan = run_json(
        cli,
        sec,
        "plan v1->v3 rotated catalog",
        [
            "manifest", "catalog", "plan",
            "--public-key", key_a_pub, "--public-key", key_b_pub,
            "--signature", sig_b,
            "--current-version", "1", "--target-version", "3",
            "--min-catalog-version", "2",
            "--allow-full", "--json", cat_v2, v1,
        ],
    )
    expect("plan decision", plan["decision"], "patches")
    expect("plan total_download_bytes", plan["total_download_bytes"], str(two_hop_bytes))
    expect("plan step count", len(plan["steps"]), 2)
    expect("plan signer_key_id", plan["signer_key_id"], meta_b["key_id"])

    # 6. Red-team rejections: downgrade (v2 -> v1), anti-replay (--min-catalog-version 2 on v1), tampered catalog.
    err_downgrade = run_cli(
        cli,
        sec,
        "catalog downgrade v2->v1",
        [
            "manifest", "catalog", "plan",
            "--public-key", key_a_pub, "--public-key", key_b_pub,
            "--signature", sig_b,
            "--current-version", "2", "--target-version", "1",
            "--json", cat_v2, v2,
        ],
        expected_code=1,
    )
    require(b"downgrade rejected" in err_downgrade.stderr, f"unexpected downgrade stderr: {err_downgrade.stderr!r}")

    err_replay = run_cli(
        cli,
        sec,
        "catalog anti-replay",
        [
            "manifest", "catalog", "verify",
            "--public-key", key_a_pub, "--public-key", key_b_pub,
            "--signature", sig_a, "--min-catalog-version", "2",
            "--json", cat_v1,
        ],
        expected_code=1,
    )
    require(b"catalog rollback rejected" in err_replay.stderr, f"unexpected replay stderr: {err_replay.stderr!r}")

    tampered_cat = sec / "catalog-tampered.json"
    tampered_cat.write_bytes(cat_v2.read_bytes() + b" ")
    err_tamper = run_cli(
        cli,
        sec,
        "catalog tampered",
        [
            "manifest", "catalog", "verify",
            "--public-key", key_a_pub, "--public-key", key_b_pub,
            "--signature", sig_b, "--json", tampered_cat,
        ],
        expected_code=1,
    )
    require(b"catalog_sha256 mismatch" in err_tamper.stderr, f"unexpected tamper stderr: {err_tamper.stderr!r}")

    savings_pct = (1.0 - two_hop_bytes / len(v3_bytes)) * 100.0
    return (
        f"Key A->B rotation verified, 2-hop={two_hop_bytes}B vs {len(v3_bytes)}B "
        f"({savings_pct:.1f}% saved); downgrade/replay/tamper rejected"
    )


def pillar_signed_dir_delta(cli: Path, work: Path) -> str:
    sec = work / "pillar_dir"
    sec.mkdir()

    # Reuse dedicated signing keys for dir bundle (overlap store [key1, key2]).
    k1_priv, k1_pub = sec / "dir-k1.key", sec / "dir-k1.pub"
    k2_priv, k2_pub = sec / "dir-k2.key", sec / "dir-k2.pub"
    k1_meta = run_json(cli, sec, "dir keygen 1", ["manifest", "keygen", "--json", k1_priv, k1_pub])
    run_json(cli, sec, "dir keygen 2", ["manifest", "keygen", "--json", k2_priv, k2_pub])

    logo = lcg_bytes(0x70030001, 1024)
    guide = lcg_bytes(0x70030002, 2048)
    app_v1 = lcg_bytes(0x70030003, 4096)
    app_v2 = app_v1[:1600] + b"MOONBSDIFF-070-APP-V2!" + app_v1[1622:]

    old_files = {
        "assets/logo.bin": logo,
        "docs/guide.txt": guide,
        "bin/app.bin": app_v1,
        "VERSION": b"0.6.0\n",
        "legacy/obsolete.cfg": b"deprecated=true\n",
    }
    new_files = {
        "assets/logo.bin": logo,                 # unchanged (0 B)
        "docs/guide-v2.txt": guide,              # renamed (0 B)
        "bin/app.bin": app_v2,                   # patched (BSDIFF40)
        "VERSION": b"0.7.0\n",                   # modified tiny -> full_fallback=true
        "notes/release.txt": b"Welcome to 0.7.0\n",  # added
    }
    old_dir = sec / "tree_v1"
    new_dir = sec / "tree_v2"
    bundle_dir = sec / "bundle_v1_to_v2"
    restored_dir = sec / "restored_v2"
    write_tree(old_dir, old_files)
    write_tree(new_dir, new_files)

    expected_old_hash = canonical_tree_sha256(old_files)
    expected_new_hash = canonical_tree_sha256(new_files)

    # 1. Signed dir-diff.
    diff_doc = run_json(
        cli,
        sec,
        "dir-diff signed",
        ["dir-diff", "--private-key", k1_priv, "--json", old_dir, new_dir, bundle_dir],
    )
    expect("dir-diff signed", diff_doc["signed"], True)
    expect("dir-diff signer_key_id", diff_doc["signer_key_id"], k1_meta["key_id"])
    expect("dir-diff unchanged_count", diff_doc["unchanged_count"], 1)
    expect("dir-diff renamed_count", diff_doc["renamed_count"], 1)
    expect("dir-diff patched_count", diff_doc["patched_count"], 1)
    expect("dir-diff added_count", diff_doc["added_count"], 2)
    expect("dir-diff full_fallback_count", diff_doc["full_fallback_count"], 1)
    expect("dir-diff deleted_count", diff_doc["deleted_count"], 2)
    expect("dir-diff old_tree_sha256", diff_doc["old_tree_sha256"], expected_old_hash)
    expect("dir-diff new_tree_sha256", diff_doc["new_tree_sha256"], expected_new_hash)
    sig_path = bundle_dir / "dir-manifest.sig"
    require(sig_path.is_file(), "missing dir-manifest.sig")

    # 2. Signed dir-verify with rotated trust store [k2, k1].
    ver_doc = run_json(
        cli,
        sec,
        "dir-verify signed",
        [
            "dir-verify",
            "--public-key", k2_pub, "--public-key", k1_pub,
            "--signature", sig_path, "--json",
            old_dir, bundle_dir,
        ],
    )
    expect("dir-verify valid", ver_doc["valid"], True)
    expect("dir-verify signed", ver_doc["signed"], True)
    expect("dir-verify signer_key_id", ver_doc["signer_key_id"], k1_meta["key_id"])
    expect("dir-verify new_tree_sha256", ver_doc["new_tree_sha256"], expected_new_hash)

    # 3. Signed dir-patch restores byte-for-byte with matching tree_sha256.
    patch_doc = run_json(
        cli,
        sec,
        "dir-patch signed",
        [
            "dir-patch",
            "--public-key", k2_pub, "--public-key", k1_pub,
            "--signature", sig_path, "--json",
            old_dir, bundle_dir, restored_dir,
        ],
    )
    expect("dir-patch new_tree_sha256", patch_doc["new_tree_sha256"], expected_new_hash)
    restored_files = read_tree(restored_dir)
    expect("dir-patch byte-for-byte tree", restored_files, new_files)
    expect("dir-patch independent tree_sha256", canonical_tree_sha256(restored_files), expected_new_hash)

    # 4. Tampered blob rejected before creating output.
    first_blob = sorted((bundle_dir / "blobs").iterdir())[0]
    orig_blob = first_blob.read_bytes()
    tampered_out = sec / "tampered_out"
    try:
        first_blob.write_bytes(orig_blob[:-1] + bytes([orig_blob[-1] ^ 0xFF]))
        run_cli(
            cli,
            sec,
            "dir-patch tampered blob",
            [
                "dir-patch",
                "--public-key", k1_pub, "--signature", sig_path,
                old_dir, bundle_dir, tampered_out,
            ],
            expected_code=1,
        )
        require(not tampered_out.exists(), "tampered dir-patch must not create OUTPUT_DIR")
    finally:
        first_blob.write_bytes(orig_blob)

    # 5. Existing output dir refusal preserves existing contents.
    existing_out = sec / "existing_out"
    existing_out.mkdir()
    sentinel = existing_out / "keep.txt"
    sentinel.write_bytes(b"preserve-existing")
    run_cli(
        cli,
        sec,
        "dir-patch existing output refusal",
        [
            "dir-patch",
            "--public-key", k1_pub, "--signature", sig_path,
            old_dir, bundle_dir, existing_out,
        ],
        expected_code=1,
    )
    expect("existing output preserved", sentinel.read_bytes(), b"preserve-existing")

    delta_bytes = int(diff_doc["delta_payload_bytes"])
    new_bytes = int(diff_doc["new_total_bytes"])
    savings_pct = (1.0 - delta_bytes / new_bytes) * 100.0
    return (
        f"delta={delta_bytes}B vs {new_bytes}B ({savings_pct:.1f}% saved; "
        f"1 unchanged, 1 renamed, 1 patched, 2 added [1 fallback], 2 deleted), "
        f"tree_sha256 verified, tamper & no-overwrite refused"
    )


def pillar_web_studio() -> str:
    proc = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "test_web_studio.py"), "-v"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=180,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"test_web_studio.py failed (exit {proc.returncode}):\n"
            f"STDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}"
        )
    summary_line = ""
    for line in proc.stderr.splitlines():
        if line.startswith("Ran "):
            summary_line = line.strip()
    return f"Node ESM suite passed ({summary_line or 'OK'})"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--cli",
        type=Path,
        required=True,
        help="Path to the moonbsdiff native CLI executable.",
    )
    parser.add_argument(
        "--skip-web",
        action="store_true",
        help="Skip building and verifying examples/web-studio via Node.js.",
    )
    args = parser.parse_args(argv)

    cli = args.cli.resolve()
    if not cli.is_file():
        parser.error(f"MoonBSDiff executable not found: {cli}")

    try:
        with tempfile.TemporaryDirectory(prefix="moonbsdiff-070-acceptance-") as tmp:
            work = Path(tmp)
            scorecard: list[tuple[str, str, str]] = []

            s1 = pillar_patch_forensics(cli, work)
            scorecard.append(("1. Patch Forensics (inspect --analyze)", "PASS", s1))

            s2 = pillar_signed_catalog(cli, work)
            scorecard.append(("2. Signed Release Catalog & Rotation", "PASS", s2))

            s3 = pillar_signed_dir_delta(cli, work)
            scorecard.append(("3. Signed Directory Delta Bundle", "PASS", s3))

            if args.skip_web:
                scorecard.append(("4. Differentiated Web Studio", "SKIP", "--skip-web specified"))
            else:
                s4 = pillar_web_studio()
                scorecard.append(("4. Differentiated Web Studio", "PASS", s4))

        print("=== MoonBSDiff 0.7.0 Acceptance Scorecard ===")
        for title, status, detail in scorecard:
            print(f"[{status}] {title}: {detail}")
        print("ACCEPTANCE 0.7.0 PASS")
        return 0
    except (OSError, RuntimeError, ValueError) as err:
        print(f"Acceptance 0.7.0 failed: {err}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
