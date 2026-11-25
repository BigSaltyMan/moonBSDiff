"""Build the MoonBSDiff Web Studio MoonBit JS core and stage dist/studio.js."""
from __future__ import annotations

import argparse
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_TARGET_DIR = ROOT / "_build" / "web-studio"
DEFAULT_OUTPUT = ROOT / "examples" / "web-studio" / "dist" / "studio.js"


def build_studio(
    target_dir: pathlib.Path,
    output_path: pathlib.Path,
    release: bool = True,
    check_only: bool = False,
) -> pathlib.Path:
    moon_bin = shutil.which("moon")
    if not moon_bin:
        raise SystemExit(
            "moon executable not found on PATH; install MoonBit or add its bin directory to PATH."
        )
    cmd = [
        moon_bin,
        "check" if check_only else "build",
        "cmd/studio",
        "--target",
        "js",
        "--frozen",
        "--deny-warn",
        "--target-dir",
        str(target_dir),
    ]
    if not check_only and release:
        cmd.append("--release")

    subprocess.run(cmd, cwd=ROOT, check=True)
    if check_only:
        return output_path

    profile = "release" if release else "debug"
    artifact = target_dir / "js" / profile / "build" / "cmd" / "studio" / "studio.js"
    if not artifact.is_file():
        raise SystemExit(f"missing compiled JS studio artifact: {artifact}")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(artifact, output_path)
    return output_path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Build MoonBSDiff cmd/studio to ES module for examples/web-studio."
    )
    parser.add_argument(
        "--target-dir",
        type=pathlib.Path,
        default=DEFAULT_TARGET_DIR,
        help="MoonBit build target directory (default: _build/web-studio).",
    )
    parser.add_argument(
        "--output",
        type=pathlib.Path,
        default=DEFAULT_OUTPUT,
        help="Destination path for compiled studio.js ES module.",
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="Build in debug profile instead of release profile.",
    )
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="Run moon check --deny-warn without staging dist/studio.js.",
    )
    args = parser.parse_args(argv)
    cwd = pathlib.Path.cwd()
    target_dir = (
        args.target_dir if args.target_dir.is_absolute() else (cwd / args.target_dir)
    ).resolve()
    output_path = (
        args.output if args.output.is_absolute() else (cwd / args.output)
    ).resolve()
    staged = build_studio(
        target_dir=target_dir,
        output_path=output_path,
        release=not args.debug,
        check_only=args.check_only,
    )
    if args.check_only:
        print("Web Studio JS check passed.")
    else:
        print(f"Web Studio JS module staged: {staged} ({staged.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
