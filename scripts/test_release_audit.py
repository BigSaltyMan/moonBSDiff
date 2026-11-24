import pathlib
import tempfile
import unittest
import zipfile

from release_audit import (
    REQUIRED_PACKAGE_MEMBERS,
    REQUIRED_SOURCE_ARCHIVE_MEMBERS,
    audit_package_policy,
    audit_release_package,
    audit_source_archive,
    audit_zip,
    expected_package_files,
    sha,
)


def minimal_source_archive():
    files = {}
    for name in REQUIRED_PACKAGE_MEMBERS + REQUIRED_SOURCE_ARCHIVE_MEMBERS:
        files[name] = ("content:" + name).encode("utf8")
    # Also include representative non-required library and excluded repository files.
    files["diff.mbt"] = b"diff-source"
    files["diff_test.mbt"] = b"diff-test"
    files["matching_wbtest.mbt"] = b"matching-wbtest"
    files["manifest/bundle_test.mbt"] = b"manifest-test"
    files["internal/bzip2/bwt_wbtest.mbt"] = b"bwt-wbtest"
    files["examples/index-reuse/main.mbt"] = b"example"
    files[".gitignore"] = b"_build/\n"
    return files


def write_zip(path, entries):
    with zipfile.ZipFile(path, "w") as z:
        for name, raw in entries.items():
            z.writestr(name, raw)


class AuditTests(unittest.TestCase):
    def test_exact_and_rejected_members(self):
        with tempfile.TemporaryDirectory() as folder:
            p = pathlib.Path(folder) / "source.zip"
            expected = {"a.mbt": sha(b"expected")}
            for mode in ["valid", "extra", "changed", "missing", "duplicate", "traversal"]:
                with zipfile.ZipFile(p, "w") as z:
                    if mode != "missing":
                        z.writestr("a.mbt", b"changed" if mode == "changed" else b"expected")
                    if mode == "extra":
                        z.writestr("extra.exe", b"extra")
                    if mode == "duplicate":
                        z.writestr("a.mbt", b"expected")
                    if mode == "traversal":
                        z.writestr("../escape.mbt", b"escape")
                if mode == "valid":
                    self.assertEqual(audit_zip(p, expected), 1)
                else:
                    with self.assertRaises(RuntimeError):
                        audit_zip(p, expected)

    def test_trimmed_release_package_passes(self):
        raw_files = minimal_source_archive()
        source_hashes = {name: sha(raw) for name, raw in raw_files.items()}
        packaged = expected_package_files(source_hashes)
        self.assertIn("diff.mbt", packaged)
        self.assertIn("LICENSE", packaged)
        self.assertIn("internal/bzip2/LICENSE", packaged)
        for excluded in (
            "diff_test.mbt",
            "matching_wbtest.mbt",
            "manifest/bundle_test.mbt",
            "internal/bzip2/bwt_wbtest.mbt",
            "cmd/main/native_io.c",
            "docs/acceptance.md",
            "scripts/run_update_demo.py",
            "testdata/upstream/seeded-random/old.bin",
            "tools/oracle/BSDIFF-LICENSE.txt",
            "examples/index-reuse/main.mbt",
            ".moonignore",
            ".gitignore",
        ):
            self.assertNotIn(excluded, packaged)
        with tempfile.TemporaryDirectory() as folder:
            p = pathlib.Path(folder) / "candidate.zip"
            write_zip(p, {name: raw_files[name] for name in packaged})
            count, audited = audit_release_package(p, source_hashes)
            self.assertEqual(count, len(packaged))
            self.assertEqual(audited, packaged)

    def test_forbidden_directory_or_test_file_in_zip_rejected(self):
        raw_files = minimal_source_archive()
        source_hashes = {name: sha(raw) for name, raw in raw_files.items()}
        packaged = expected_package_files(source_hashes)
        forbidden_cases = [
            "testdata/upstream/seeded-random/old.bin",
            "scripts/run_update_demo.py",
            "tools/oracle/BSDIFF-LICENSE.txt",
            "docs/acceptance.md",
            "examples/index-reuse/main.mbt",
            "cmd/main/native_io.c",
            "diff_test.mbt",
            "matching_wbtest.mbt",
            "manifest/bundle_test.mbt",
            "internal/bzip2/bwt_wbtest.mbt",
            "stray_root_notes.md",
        ]
        with tempfile.TemporaryDirectory() as folder:
            for extra in forbidden_cases:
                with self.subTest(extra=extra):
                    with self.assertRaises(RuntimeError):
                        audit_package_policy(list(packaged) + [extra])
                    p = pathlib.Path(folder) / "bad.zip"
                    entries = {name: raw_files[name] for name in packaged}
                    entries[extra] = raw_files.get(extra, b"stray")
                    write_zip(p, entries)
                    with self.assertRaises(RuntimeError):
                        audit_release_package(p, source_hashes)

    def test_missing_required_license_or_library_member_rejected(self):
        raw_files = minimal_source_archive()
        source_hashes = {name: sha(raw) for name, raw in raw_files.items()}
        packaged = expected_package_files(source_hashes)
        critical_members = [
            "LICENSE",
            "README.md",
            "README.zh-CN.md",
            "moon.mod",
            "pkg.generated.mbti",
            "manifest/pkg.generated.mbti",
            "internal/bzip2/LICENSE",
            "internal/bzip2/source-lock.json",
            "internal/bzip2/changes.patch",
            "internal/bzip2/encoder-changes.patch",
            "internal/manifest/version.mbt",
        ]
        with tempfile.TemporaryDirectory() as folder:
            for missing in critical_members:
                with self.subTest(missing=missing):
                    reduced = [name for name in packaged if name != missing]
                    with self.assertRaises(RuntimeError):
                        audit_package_policy(reduced)
                    reduced_source = {k: v for k, v in source_hashes.items() if k != missing}
                    p = pathlib.Path(folder) / "missing.zip"
                    write_zip(p, {name: raw_files[name] for name in reduced})
                    with self.assertRaises(RuntimeError):
                        audit_release_package(p, reduced_source)

    def test_missing_required_source_archive_member_rejected(self):
        raw_files = minimal_source_archive()
        for missing in (".moonignore", "tools/oracle/BSDIFF-LICENSE.txt", "scripts/run_update_demo.py"):
            with self.subTest(missing=missing):
                reduced = [name for name in raw_files if name != missing]
                with self.assertRaises(RuntimeError):
                    audit_source_archive(reduced)

    def test_dirty_or_modified_member_rejected(self):
        raw_files = minimal_source_archive()
        source_hashes = {name: sha(raw) for name, raw in raw_files.items()}
        packaged = expected_package_files(source_hashes)
        with tempfile.TemporaryDirectory() as folder:
            p = pathlib.Path(folder) / "dirty.zip"
            entries = {name: raw_files[name] for name in packaged}
            entries["diff.mbt"] = b"tampered-bytes"
            write_zip(p, entries)
            with self.assertRaises(RuntimeError):
                audit_release_package(p, source_hashes)


if __name__ == "__main__":
    unittest.main()
