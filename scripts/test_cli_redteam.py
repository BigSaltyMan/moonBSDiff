"""Cross-platform CLI regression suite for red-team security and parity fixes."""

import argparse
import bz2
import ctypes
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from build_cli import version
from test_cli_stream import envelope


EXE = None


def identity(data):
    return {"size_bytes": str(len(data)), "sha256": hashlib.sha256(data).hexdigest()}


def make_manifest(old_bytes, new_bytes, patch_bytes):
    return {
        "schema_version": 1,
        "patch_format": "BSDIFF40",
        "producer": {"name": "moonbsdiff", "version": version()},
        "old": identity(old_bytes),
        "new": identity(new_bytes),
        "patch": identity(patch_bytes),
    }


def _win_extended_dir(path):
    resolved = str(path.resolve()).rstrip("\\")
    if resolved.startswith("\\\\?\\"):
        return resolved
    if resolved.startswith("\\\\"):
        return "\\\\?\\UNC\\" + resolved[2:]
    return "\\\\?\\" + resolved


def _utf16_buffer(text):
    """Encode text (including lone UTF-16 surrogates) into a mutable NUL-terminated buffer."""
    units = []
    for ch in text:
        code = ord(ch)
        if code <= 0xFFFF:
            units.append(code)
        else:
            code -= 0x10000
            units.append(0xD800 | (code >> 10))
            units.append(0xDC00 | (code & 0x3FF))
    units.append(0)
    return (ctypes.c_uint16 * len(units))(*units)


def _run_win_raw_cmdline(exe, raw_args, cwd):
    """Spawn exe via Win32 CreateProcessW with a raw UTF-16 command line."""
    from ctypes import wintypes

    GENERIC_READ = 0x80000000
    GENERIC_WRITE = 0x40000000
    FILE_SHARE_READ = 0x00000001
    FILE_SHARE_WRITE = 0x00000002
    OPEN_EXISTING = 3
    CREATE_ALWAYS = 2
    FILE_ATTRIBUTE_NORMAL = 0x00000080
    STARTF_USESTDHANDLES = 0x00000100
    CREATE_NO_WINDOW = 0x08000000
    WAIT_OBJECT_0 = 0x00000000
    INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value

    class SECURITY_ATTRIBUTES(ctypes.Structure):
        _fields_ = [
            ("nLength", wintypes.DWORD),
            ("lpSecurityDescriptor", wintypes.LPVOID),
            ("bInheritHandle", wintypes.BOOL),
        ]

    class STARTUPINFOW(ctypes.Structure):
        _fields_ = [
            ("cb", wintypes.DWORD),
            ("lpReserved", wintypes.LPWSTR),
            ("lpDesktop", wintypes.LPWSTR),
            ("lpTitle", wintypes.LPWSTR),
            ("dwX", wintypes.DWORD),
            ("dwY", wintypes.DWORD),
            ("dwXSize", wintypes.DWORD),
            ("dwYSize", wintypes.DWORD),
            ("dwXCountChars", wintypes.DWORD),
            ("dwYCountChars", wintypes.DWORD),
            ("dwFillAttribute", wintypes.DWORD),
            ("dwFlags", wintypes.DWORD),
            ("wShowWindow", wintypes.WORD),
            ("cbReserved2", wintypes.WORD),
            ("lpReserved2", ctypes.c_void_p),
            ("hStdInput", wintypes.HANDLE),
            ("hStdOutput", wintypes.HANDLE),
            ("hStdError", wintypes.HANDLE),
        ]

    class PROCESS_INFORMATION(ctypes.Structure):
        _fields_ = [
            ("hProcess", wintypes.HANDLE),
            ("hThread", wintypes.HANDLE),
            ("dwProcessId", wintypes.DWORD),
            ("dwThreadId", wintypes.DWORD),
        ]

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

    kernel32.CreateFileW.argtypes = [
        wintypes.LPCWSTR,
        wintypes.DWORD,
        wintypes.DWORD,
        ctypes.POINTER(SECURITY_ATTRIBUTES),
        wintypes.DWORD,
        wintypes.DWORD,
        wintypes.HANDLE,
    ]
    kernel32.CreateFileW.restype = wintypes.HANDLE

    kernel32.CreateProcessW.argtypes = [
        ctypes.c_void_p,
        ctypes.c_void_p,
        ctypes.c_void_p,
        ctypes.c_void_p,
        wintypes.BOOL,
        wintypes.DWORD,
        ctypes.c_void_p,
        ctypes.c_void_p,
        ctypes.POINTER(STARTUPINFOW),
        ctypes.POINTER(PROCESS_INFORMATION),
    ]
    kernel32.CreateProcessW.restype = wintypes.BOOL

    kernel32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    kernel32.WaitForSingleObject.restype = wintypes.DWORD

    kernel32.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    kernel32.GetExitCodeProcess.restype = wintypes.BOOL

    kernel32.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
    kernel32.TerminateProcess.restype = wintypes.BOOL

    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel32.CloseHandle.restype = wintypes.BOOL

    def valid_handle(handle):
        return handle not in (None, 0, INVALID_HANDLE_VALUE)

    with tempfile.TemporaryDirectory(prefix="moonbsdiff-winraw-") as capture_dir:
        capture = Path(capture_dir)
        stdout_path = capture / "stdout.bin"
        stderr_path = capture / "stderr.bin"
        sa = SECURITY_ATTRIBUTES(ctypes.sizeof(SECURITY_ATTRIBUTES), None, True)

        stdin_h = stdout_h = stderr_h = None
        proc_h = thread_h = None
        try:
            stdin_h = kernel32.CreateFileW(
                "NUL",
                GENERIC_READ,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                ctypes.byref(sa),
                OPEN_EXISTING,
                FILE_ATTRIBUTE_NORMAL,
                None,
            )
            if not valid_handle(stdin_h):
                raise ctypes.WinError(ctypes.get_last_error())

            stdout_h = kernel32.CreateFileW(
                str(stdout_path),
                GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                ctypes.byref(sa),
                CREATE_ALWAYS,
                FILE_ATTRIBUTE_NORMAL,
                None,
            )
            if not valid_handle(stdout_h):
                raise ctypes.WinError(ctypes.get_last_error())

            stderr_h = kernel32.CreateFileW(
                str(stderr_path),
                GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                ctypes.byref(sa),
                CREATE_ALWAYS,
                FILE_ATTRIBUTE_NORMAL,
                None,
            )
            if not valid_handle(stderr_h):
                raise ctypes.WinError(ctypes.get_last_error())

            si = STARTUPINFOW()
            si.cb = ctypes.sizeof(STARTUPINFOW)
            si.dwFlags = STARTF_USESTDHANDLES
            si.hStdInput = stdin_h
            si.hStdOutput = stdout_h
            si.hStdError = stderr_h

            pi = PROCESS_INFORMATION()
            app_buf = _utf16_buffer(str(exe))
            cmd_buf = _utf16_buffer(f'"{exe}" {raw_args}')
            cwd_buf = _utf16_buffer(str(cwd))

            created = kernel32.CreateProcessW(
                ctypes.cast(app_buf, ctypes.c_void_p),
                ctypes.cast(cmd_buf, ctypes.c_void_p),
                None,
                None,
                True,
                CREATE_NO_WINDOW,
                None,
                ctypes.cast(cwd_buf, ctypes.c_void_p),
                ctypes.byref(si),
                ctypes.byref(pi),
            )
            if not created:
                raise ctypes.WinError(ctypes.get_last_error())

            proc_h = pi.hProcess
            thread_h = pi.hThread

            for handle in (stdin_h, stdout_h, stderr_h, thread_h):
                if valid_handle(handle):
                    kernel32.CloseHandle(handle)
            stdin_h = stdout_h = stderr_h = thread_h = None

            wait_rc = kernel32.WaitForSingleObject(proc_h, 30000)
            if wait_rc != WAIT_OBJECT_0:
                kernel32.TerminateProcess(proc_h, 1)
                raise TimeoutError(f"CreateProcessW child did not exit (wait={wait_rc})")

            exit_code = wintypes.DWORD(0)
            if not kernel32.GetExitCodeProcess(proc_h, ctypes.byref(exit_code)):
                raise ctypes.WinError(ctypes.get_last_error())

            kernel32.CloseHandle(proc_h)
            proc_h = None
            return exit_code.value, stdout_path.read_bytes(), stderr_path.read_bytes()
        finally:
            for handle in (stdin_h, stdout_h, stderr_h, thread_h, proc_h):
                if valid_handle(handle):
                    kernel32.CloseHandle(handle)


class RedteamCli(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="moonbsdiff-redteam-")
        self.addCleanup(self.temp.cleanup)
        self.p = Path(self.temp.name)
        self.old = self.p / "old.bin"
        self.new = self.p / "new.bin"
        self.patch = self.p / "patch.bin"
        self.manifest = self.p / "manifest.json"
        self.old.write_bytes(b"abc\x00\xff")
        self.new.write_bytes(b"abC\x00\xff!")

    def run_cli(self, args, code=0, *, cwd=None, allow_stderr=False):
        workdir = self.p if cwd is None else Path(cwd)
        before = {}
        for entry in workdir.iterdir():
            if entry.is_file() and not entry.is_symlink():
                try:
                    before[entry] = entry.read_bytes()
                except OSError:
                    pass
        result = subprocess.run(
            [str(EXE), *map(str, args)],
            cwd=workdir,
            capture_output=True,
            timeout=30,
        )
        self.assertEqual(
            result.returncode,
            code,
            result.stderr.decode("utf-8", errors="replace"),
        )
        if code:
            self.assertEqual(result.stdout, b"")
            self.assertTrue(result.stderr)
            for path, raw in before.items():
                self.assertEqual(path.read_bytes(), raw, str(path))
        elif not allow_stderr:
            self.assertEqual(result.stderr, b"")
        self.assertFalse(list(workdir.glob(".moonbsdiff-*.tmp")))
        self.assertFalse(list(workdir.glob(".moonbsdiff-compat-*")))
        return result

    def generate_bundle(self, patch_path=None, manifest_path=None):
        patch_target = self.patch if patch_path is None else Path(patch_path)
        manifest_target = self.manifest if manifest_path is None else Path(manifest_path)
        self.run_cli([
            "diff",
            "--manifest",
            manifest_target,
            self.old,
            self.new,
            patch_target,
        ])
        return patch_target, manifest_target

    def test_argument_encoding_safety(self):
        if os.name == "nt":
            for raw_args in ("inspect \uD800", "diff --\uD800 a b c"):
                with self.subTest(raw_args=repr(raw_args)):
                    exit_code, stdout, stderr = _run_win_raw_cmdline(EXE, raw_args, self.p)
                    decoded = stderr.decode("utf-8", errors="replace")
                    self.assertEqual(exit_code, 2, f"rc={exit_code:#x} stderr={decoded!r}")
                    self.assertEqual(stdout, b"")
                    self.assertIn(b"unpaired UTF-16 surrogate", stderr)
                    self.assertNotIn(b"PanicError", stderr)
            self.assertFalse((self.p / "c").exists())
        else:
            dir_bytes = os.fsencode(self.p)
            exe_bytes = os.fsencode(EXE)
            bad_patch = os.path.join(dir_bytes, b"out_\xff\xfe.patch")
            bad_manifest = os.path.join(dir_bytes, b"in_\xff\xfe.json")

            diff_res = subprocess.run(
                [exe_bytes, b"diff", os.fsencode(self.old), os.fsencode(self.new), bad_patch],
                cwd=self.p,
                capture_output=True,
                timeout=30,
            )
            self.assertEqual(
                diff_res.returncode,
                2,
                diff_res.stderr.decode("utf-8", errors="replace"),
            )
            self.assertEqual(diff_res.stdout, b"")
            self.assertIn(b"valid UTF-8", diff_res.stderr)

            entries = os.listdir(dir_bytes)
            self.assertNotIn(b"out_\xff\xfe.patch", entries)
            self.assertNotIn(b"out_\xef\xbf\xbd\xef\xbf\xbd.patch", entries)
            self.assertFalse(
                any(name.startswith(b"out_") or b"\xef\xbf\xbd" in name for name in entries),
                entries,
            )

            select_res = subprocess.run(
                [exe_bytes, b"manifest", b"select", os.fsencode(self.old), bad_manifest],
                cwd=self.p,
                capture_output=True,
                timeout=30,
            )
            self.assertEqual(
                select_res.returncode,
                2,
                select_res.stderr.decode("utf-8", errors="replace"),
            )
            self.assertEqual(select_res.stdout, b"")
            self.assertIn(b"valid UTF-8", select_res.stderr)

    def test_windows_extended_path_and_ads_preflight(self):
        patch_path, manifest_path = self.generate_bundle()
        empty_old = self.p / "empty.bin"
        empty_old.write_bytes(b"")
        empty_patch = self.p / "from-empty.patch"
        self.run_cli(["diff", empty_old, self.new, empty_patch])

        if os.name == "nt":
            base = str(self.p.resolve()).rstrip("\\")
            ext_dir = _win_extended_dir(self.p)

            for leaf, bare in (("foo.", "foo"), ("bar ", "bar")):
                target = f"{ext_dir}\\{leaf}"
                commands = [
                    ("diff", ["diff", self.old, self.new, target]),
                    ("patch-stream", ["patch", "--stream", self.old, patch_path, target]),
                    (
                        "install-full",
                        ["install-full", "--target-manifest", manifest_path, self.new, target],
                    ),
                ]
                for label, cmd in commands:
                    with self.subTest(case="extended-trailing", label=label, leaf=leaf):
                        res = self.run_cli(cmd, code=1)
                        self.assertIn(b"extended path trailing dot or space", res.stderr)
                        names = set(os.listdir(self.p))
                        self.assertNotIn(leaf, names)
                        self.assertNotIn(bare, names)
                        self.assertFalse((self.p / bare).exists())

            existing = self.p / "existing.bin"
            existing.write_bytes(b"keep-existing")
            p_patch = self.p / "p.patch"
            ext_manifest = f"{ext_dir}\\existing.bin."
            res = self.run_cli(
                ["diff", "--manifest", ext_manifest, self.old, self.new, p_patch],
                code=1,
            )
            self.assertIn(b"extended path trailing dot or space", res.stderr)
            self.assertFalse(p_patch.exists())
            self.assertEqual(existing.read_bytes(), b"keep-existing")
            self.assertNotIn("existing.bin.", os.listdir(self.p))

            ghost = self.p / "ghost.bin"
            self.assertFalse(ghost.exists())
            for ads_name in ("existing.bin:secret", "ghost.bin:secret"):
                target = f"{base}\\{ads_name}"
                commands = [
                    ("diff", ["diff", self.old, self.new, target]),
                    ("patch-stream", ["patch", "--stream", self.old, patch_path, target]),
                    (
                        "install-full",
                        ["install-full", "--target-manifest", manifest_path, self.new, target],
                    ),
                ]
                for label, cmd in commands:
                    with self.subTest(case="ads", label=label, ads=ads_name):
                        res = self.run_cli(cmd, code=1)
                        self.assertIn(b"alternate data streams are unsupported", res.stderr)
                        with self.assertRaises(OSError):
                            with open(target, "rb"):
                                pass
                        self.assertFalse(ghost.exists())
                        self.assertEqual(existing.read_bytes(), b"keep-existing")

            res = self.run_cli(
                [
                    "diff",
                    "--manifest",
                    "VERYLO~1.PAT",
                    self.old,
                    self.new,
                    "verylongname.patch",
                ],
                code=1,
            )
            self.assertIn(b"same target", res.stderr)
            self.assertFalse((self.p / "verylongname.patch").exists())
            self.assertFalse((self.p / "VERYLO~1.PAT").exists())

            out_patch = self.p / "nul-out.patch"
            res_diff = self.run_cli(["diff", "NUL", self.new, out_patch], code=1)
            self.assertNotIn(b"OS error 0", res_diff.stderr)
            self.assertFalse(out_patch.exists())

            for label, second_arg, out_name in (
                ("new", self.new, "nul-out2.bin"),
                ("valid-empty-patch", empty_patch, "nul-out3.bin"),
            ):
                with self.subTest(case="nul-stream", label=label):
                    out_bin = self.p / out_name
                    res_stream = self.run_cli(
                        ["patch", "--stream", "NUL", second_arg, out_bin],
                        code=1,
                    )
                    self.assertNotIn(b"OS error 0", res_stream.stderr)
                    self.assertFalse(out_bin.exists())
        else:
            out_patch = self.p / "devnull-out.patch"
            res_diff = self.run_cli(["diff", "/dev/null", self.new, out_patch], code=1)
            self.assertIn(b"regular file", res_diff.stderr)
            self.assertNotIn(b"OS error 0", res_diff.stderr)
            self.assertFalse(out_patch.exists())

            out_bin = self.p / "devnull-out2.bin"
            res_stream = self.run_cli(
                ["patch", "--stream", "/dev/null", empty_patch, out_bin],
                code=1,
            )
            self.assertIn(b"regular file", res_stream.stderr)
            self.assertNotIn(b"OS error 0", res_stream.stderr)
            self.assertFalse(out_bin.exists())

    def test_diff_many_dangling_symlink_blocked(self):
        # Missing group-2 input must fail at preflight before group 1 delivers g1.patch.
        missing_dir = self.p / "missing-group2"
        missing_dir.mkdir()
        (missing_dir / "old.bin").write_bytes(b"shared-old")
        (missing_dir / "new1.bin").write_bytes(b"shared-new-1")
        outputs = ("g1.patch", "g1.json", "g2.patch", "g2.json")

        res_missing = self.run_cli(
            [
                "diff-many",
                "old.bin",
                "new1.bin",
                "g1.patch",
                "g1.json",
                "missing_new2.bin",
                "g2.patch",
                "g2.json",
            ],
            code=1,
            cwd=missing_dir,
        )
        self.assertIn(b"completed groups: 0", res_missing.stderr)
        for name in outputs:
            self.assertFalse((missing_dir / name).exists(), name)

        # Dangling symlink pointing to group 1's output must also fail at preflight.
        sym_dir = self.p / "dangling-symlink"
        sym_dir.mkdir()
        (sym_dir / "old.bin").write_bytes(b"shared-old")
        (sym_dir / "new1.bin").write_bytes(b"shared-new-1")
        link = sym_dir / "new2_link"

        symlink_created = False
        if os.name == "nt":
            try:
                link.symlink_to("g1.patch")
                symlink_created = True
            except OSError:
                symlink_created = False
        else:
            link.symlink_to("g1.patch")
            symlink_created = True

        if symlink_created:
            self.assertTrue(link.is_symlink())
            self.assertFalse(link.exists())
            res_sym = self.run_cli(
                [
                    "diff-many",
                    "old.bin",
                    "new1.bin",
                    "g1.patch",
                    "g1.json",
                    "new2_link",
                    "g2.patch",
                    "g2.json",
                ],
                code=1,
                cwd=sym_dir,
            )
            self.assertIn(b"completed groups: 0", res_sym.stderr)
            for name in outputs:
                self.assertFalse((sym_dir / name).exists(), name)
            self.assertTrue(link.is_symlink())

    def test_stream_and_memory_parity_and_diagnostics(self):
        # 1. Header new_bytes mismatch (header=25, manifest=20) under --max-new-bytes 20 --max-output-bytes 20.
        old_20 = b"01234567890123456789"
        new_20 = b"ABCDEFGHIJ0123456789"
        empty = bz2.compress(b"")
        mismatch_patch_bytes = envelope([empty, empty, empty], 25)
        old_20_path = self.p / "old20.bin"
        mismatch_patch = self.p / "mismatch25.patch"
        mismatch_manifest = self.p / "mismatch20.json"
        old_20_path.write_bytes(old_20)
        mismatch_patch.write_bytes(mismatch_patch_bytes)
        mismatch_manifest.write_text(
            json.dumps(make_manifest(old_20, new_20, mismatch_patch_bytes)),
            encoding="utf-8",
        )

        expected_mismatch = b"patch header/new size mismatch: header 25, manifest 20"
        for mode in ([], ["--stream"]):
            with self.subTest(verify_mode=mode):
                res = self.run_cli(
                    [
                        "verify",
                        *mode,
                        "--manifest",
                        mismatch_manifest,
                        "--max-new-bytes",
                        "20",
                        "--max-output-bytes",
                        "20",
                        old_20_path,
                        mismatch_patch,
                    ],
                    code=1,
                )
                self.assertIn(expected_mismatch, res.stderr)

        # 2. patch --stream (default and --progress json) to nonexistent parent dir.
        patch_path, _ = self.generate_bundle()
        missing_parent = self.p / "no_such_parent" / "out.bin"
        self.assertFalse(missing_parent.parent.exists())

        res_default = self.run_cli(
            ["patch", "--stream", self.old, patch_path, missing_parent],
            code=1,
        )
        default_text = res_default.stderr.decode("utf-8", errors="replace").strip()
        self.assertTrue(default_text)
        self.assertFalse(default_text.startswith("; "), default_text)
        self.assertFalse(default_text.startswith("moonbsdiff: ; "), default_text)
        for line in default_text.splitlines():
            self.assertFalse(line.startswith("; "), line)
            self.assertFalse(line.startswith("moonbsdiff: ; "), line)

        res_json = self.run_cli(
            ["patch", "--stream", "--progress", "json", self.old, patch_path, missing_parent],
            code=1,
        )
        rows = [json.loads(line) for line in res_json.stderr.decode("utf-8").splitlines()]
        self.assertTrue(rows)
        self.assertEqual(rows[-1]["event"], "error")
        self.assertFalse(rows[-1]["output_committed"])
        err_message = rows[-1]["message"]
        self.assertTrue(err_message)
        self.assertFalse(err_message.startswith("; "), err_message)
        self.assertFalse(err_message.startswith("moonbsdiff: ; "), err_message)

        # 3. patch --stream --progress text reports unquoted integer total_bytes=<N>.
        restored = self.p / "restored-progress.bin"
        res_text = self.run_cli(
            ["patch", "--stream", "--progress", "text", self.old, patch_path, restored],
            code=0,
            allow_stderr=True,
        )
        self.assertEqual(restored.read_bytes(), self.new.read_bytes())
        progress_text = res_text.stderr.decode("utf-8")
        expected_len = len(self.new.read_bytes())
        self.assertIn(f"total_bytes={expected_len}", progress_text)
        self.assertNotIn(f'total_bytes="{expected_len}"', progress_text)
        self.assertNotIn('total_bytes="', progress_text)

        # 4. patch vs inspect --deep on invalid bzip2 marker BZh9BADMRK both report offset: Some(36).
        marker_patch = self.p / "bad-marker.patch"
        marker_patch.write_bytes(envelope([b"BZh9BADMRK", empty, empty], 0))
        marker_out = self.p / "bad-marker.out"

        res_patch = self.run_cli(["patch", self.old, marker_patch, marker_out], code=1)
        self.assertIn(b"offset: Some(36)", res_patch.stderr)
        self.assertFalse(marker_out.exists())

        res_deep = self.run_cli(["inspect", "--deep", marker_patch], code=1)
        self.assertIn(b"offset: Some(36)", res_deep.stderr)

    def test_input_alias_and_install_full_and_plan_diagnostics(self):
        patch_path, manifest_path = self.generate_bundle()
        same_input = b"output is the same file as an input"

        # 1. manifest create old new patch patch
        res = self.run_cli(
            ["manifest", "create", self.old, self.new, patch_path, patch_path],
            code=1,
        )
        self.assertIn(same_input, res.stderr)

        # 2. patch [--stream] --manifest m.json old p.patch m.json
        for mode in ([], ["--stream"]):
            with self.subTest(patch_alias_mode=mode):
                res = self.run_cli(
                    [
                        "patch",
                        *mode,
                        "--manifest",
                        manifest_path,
                        self.old,
                        patch_path,
                        manifest_path,
                    ],
                    code=1,
                )
                self.assertIn(same_input, res.stderr)

        # 3. patch-chain --target-manifest m.json miss.bin miss.bin p.patch m.json
        miss = self.p / "miss.bin"
        self.assertFalse(miss.exists())
        res = self.run_cli(
            [
                "patch-chain",
                "--target-manifest",
                manifest_path,
                miss,
                miss,
                patch_path,
                manifest_path,
            ],
            code=1,
        )
        self.assertIn(b"paths resolve to the same target", res.stderr)
        self.assertNotIn(b"patch and manifest have the same target", res.stderr)
        self.assertFalse(miss.exists())

        # 4. patch-chain where output equals an existing step patch
        res = self.run_cli(
            [
                "patch-chain",
                "--target-manifest",
                manifest_path,
                self.old,
                patch_path,
                patch_path,
                manifest_path,
            ],
            code=1,
        )
        self.assertIn(same_input, res.stderr)

        # 5. install-full opens missing source before trying destination temp dir
        missing_src = self.p / "missing_src.bin"
        missing_out = self.p / "missing_dir" / "out.bin"
        res = self.run_cli(
            [
                "install-full",
                "--target-manifest",
                manifest_path,
                missing_src,
                missing_out,
            ],
            code=1,
        )
        self.assertIn(b"open downloaded file", res.stderr)
        self.assertFalse(missing_out.parent.exists())

        # 6. manifest plan with --max-steps 1 and empty candidates does not claim effective --max-steps=0
        res = self.run_cli(
            [
                "manifest",
                "plan",
                "--max-steps",
                "1",
                "--target-manifest",
                manifest_path,
                self.old,
            ],
            code=1,
        )
        self.assertIn(b"no reachable path", res.stderr)
        self.assertNotIn(b"effective --max-steps=0", res.stderr)

        # 7. Unknown option --bogus yields exit code 2 and "unknown option: --bogus"
        unknown_cases = [
            ["manifest", "plan", "--bogus", "--target-manifest", manifest_path, self.old],
            ["inspect", "--bogus", patch_path],
            ["install-full", "--bogus"],
        ]
        for argv in unknown_cases:
            with self.subTest(unknown_option=argv):
                res = self.run_cli(argv, code=2)
                self.assertIn(b"unknown option: --bogus", res.stderr)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", required=True, type=Path)
    args = parser.parse_args()
    EXE = args.exe.resolve(strict=True)
    if not EXE.is_file():
        raise SystemExit("CLI executable missing")
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(RedteamCli)
    )
    if not result.wasSuccessful() or result.testsRun != 5 or result.skipped:
        raise SystemExit(1)
