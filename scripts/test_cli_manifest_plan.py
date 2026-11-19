"""Verify shortest-path choices and apply a real two-hop patch plan."""

import argparse
import bz2
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from build_cli import ROOT, version
from test_cli_manifest_create import identity
from test_cli_stream import envelope, integer


EXE = None
UPSTREAM = ROOT / "testdata/upstream/seeded-random"


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
    # A valid direct patch that carries the complete target in Extra.
    control = integer(0) + integer(len(target)) + integer(0)
    write("v1-to-v3.patch", envelope([bz2.compress(control), bz2.compress(b""),
                                      bz2.compress(target)], len(target)))
    invoke("manifest", "create", "installed.bin", "v3.bin", "v1-to-v3.patch", "v1-to-v3.json")


class ManifestPlanFixture(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory(prefix="moonbsdiff-plan-")
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)

    def invoke(self, *args, code=0):
        result = subprocess.run([EXE, *args], cwd=self.folder,
                                capture_output=True, timeout=30)
        self.assertEqual(result.returncode, code, result.stderr.decode(errors="replace"))
        if code == 0:
            self.assertEqual(result.stderr, b"")
        else:
            self.assertEqual(result.stdout, b"")
            self.assertTrue(result.stderr)
        return result

    def write(self, name, data):
        (self.folder / name).write_bytes(data)

    def read(self, name):
        return (self.folder / name).read_bytes()

    def plan(self, marker, *edges, code=0, options=()):
        before = {p.name: p.read_bytes() for p in self.folder.iterdir()}
        result = self.invoke("manifest", "plan", "--target-manifest", marker,
                             *options, "installed.bin", *edges, code=code)
        self.assertEqual({p.name: p.read_bytes() for p in self.folder.iterdir()}, before)
        return result

    def edge(self, path, old, new, cost):
        # Declared-cost graph fixture. This case only exercises planning.
        record = {"schema_version": 1, "patch_format": "BSDIFF40",
                  "producer": {"name": "moonbsdiff", "version": version()},
                  "old": identity(old), "new": identity(new),
                  "patch": identity(bytes(cost))}
        self.write(path, json.dumps(record).encode("utf-8"))
        return path


class ManifestPlan(ManifestPlanFixture):
    def test_cheaper_two_hops_actually_restore_target(self):
        start, middle, target = prepare_two_hop(self.write, self.invoke)
        prepare_direct(self.write, self.invoke, target)
        paths = ("v1-to-v2.json", "v2-to-v3.json")
        inputs = ((start, middle), (middle, target))
        steps, patches = [], {}
        for path, (old, new) in zip(paths + ("v1-to-v3.json",), inputs + ((start, target),)):
            patch_path = Path(path).with_suffix(".patch").name
            patch = self.read(patch_path)
            patches[patch_path] = patch
            (self.folder / patch_path).unlink()
            declared = json.loads(self.read(path))
            expected = {"old": identity(old), "new": identity(new), "patch": identity(patch)}
            self.assertEqual({key: declared[key] for key in expected}, expected)
            if path in paths:
                steps.append({"manifest_path": path, **expected})
        costs = [int(step["patch"]["size_bytes"]) for step in steps]
        direct = len(patches["v1-to-v3.patch"])
        self.assertLess(sum(costs), direct)

        result = self.plan(paths[1], *paths, "v1-to-v3.json")
        plan = json.loads(result.stdout)
        self.assertEqual(plan, {"schema_version": 1, "start": identity(start), "target": identity(target),
                                "total_patch_bytes": str(sum(costs)), "steps": steps})
        self.assertEqual(json.loads(self.plan(paths[1], *paths).stdout), plan)
        old_path = "installed.bin"
        for step, next_name, expected in zip(plan["steps"], ("restored-v2.bin", "restored-v3.bin"),
                                              (middle, target)):
            path = step["manifest_path"]
            patch_path = Path(path).with_suffix(".patch").name
            self.write(patch_path, patches[patch_path])
            self.invoke("patch", "--stream", "--manifest", path, old_path, patch_path, next_name)
            self.assertEqual(self.read(next_name), expected)
            old_path = next_name
        print(f"Direct: {direct} bytes. Selected: {costs[0]} + {costs[1]} = {sum(costs)} bytes. "
              f"Restored: {len(target)} bytes, SHA-256 {identity(target)['sha256']}")
        print(result.stdout.decode("utf-8").strip())

    def test_ties_parallel_edges_and_cycles(self):
        source, target = b"src", b"destination"
        self.write("installed.bin", source)
        slower = self.edge("slower.json", source, b"bee", 8)
        ab = self.edge("ab.json", source, b"bee", 4)
        ac = self.edge("ac.json", source, b"cee", 4)
        bd = self.edge("bd.json", b"bee", target, 6)
        cd = self.edge("cd.json", b"cee", target, 6)
        back = self.edge("back.json", b"bee", source, 0)
        loop = self.edge("loop.json", b"bee", b"bee", 0)
        direct = self.edge("direct.json", source, target, 10)
        tail = (slower, cd, bd, back, loop)
        for candidates, expected in [
            ((ab, ac, *tail, direct), [direct]),
            ((ab, ac, *tail), [ab, bd]),
            ((ac, ab, *tail), [ac, cd]),
        ]:
            with self.subTest(expected=expected):
                raw = self.plan(bd, *candidates).stdout
                self.assertEqual(self.plan(bd, *candidates).stdout, raw)
                plan = json.loads(raw)
                self.assertEqual(plan["total_patch_bytes"], "10")
                self.assertEqual([step["manifest_path"] for step in plan["steps"]], expected)

    def test_identity_and_validation_boundaries(self):
        old, target = b"one", b"target"
        self.write("installed.bin", old)
        first = self.edge("first.json", old, b"two", 50)
        wrong = self.edge("wrong.json", b"TWO", target, 50)
        marker = self.edge("target-label.json", old, target, 100)
        self.assertIn(b"no reachable path", self.plan(marker, first, wrong, code=1).stderr)
        self.assertIn(b"patch/max_patch_bytes", self.plan(marker, first, wrong, code=1,
                      options=("--max-patch-bytes", "99")).stderr)
        self.assertIn(b"requires --target-manifest", self.invoke(
            "manifest", "plan", "installed.bin", first, code=2).stderr)
        self.write("installed.bin", target)
        self.assertEqual(json.loads(self.plan(marker).stdout), {
            "schema_version": 1, "start": identity(target), "target": identity(target),
            "total_patch_bytes": "0", "steps": [],
        })
        self.write("broken.json", b"{")
        self.assertIn(b"'broken.json': manifest JSON:", self.plan(marker, first, "broken.json", code=1).stderr)


class ManifestPlanStepLimit(ManifestPlanFixture):
    def test_real_one_and_two_step_routes(self):
        start, _, target = prepare_two_hop(self.write, self.invoke)
        prepare_direct(self.write, self.invoke, target)
        candidates = ("v1-to-v2.json", "v2-to-v3.json", "v1-to-v3.json")
        for max_steps, expected_paths, expected_sizes in [
            ("1", candidates[2:], [2532]),
            ("2", candidates[:2], [204, 164]),
        ]:
            with self.subTest(max_steps=max_steps):
                raw = self.plan(candidates[1], *candidates, options=("--max-steps", max_steps, "--"))
                plan = json.loads(raw.stdout)
                paths = [step["manifest_path"] for step in plan["steps"]]
                patches = [Path(path).with_suffix(".patch").name for path in paths]
                sizes = [len(self.read(path)) for path in patches]
                self.assertEqual(paths, list(expected_paths))
                self.assertEqual(sizes, expected_sizes)
                expected_steps = []
                for path, patch in zip(paths, patches):
                    manifest = json.loads(self.read(path))
                    expected_steps.append({"manifest_path": path, "old": manifest["old"],
                                           "new": manifest["new"], "patch": identity(self.read(patch))})
                self.assertEqual(plan, {
                    "schema_version": 1, "start": identity(start), "target": identity(target),
                    "total_patch_bytes": str(sum(sizes)), "steps": expected_steps,
                })
                print(f"Cap {max_steps}: {sizes} = {sum(sizes)} bytes")
                if max_steps == "2":
                    ordered = [arg for patch, path in zip(patches, paths) for arg in (patch, path)]
                    verified = self.invoke("verify-chain", "--target-manifest", candidates[1],
                                           "--", "installed.bin", *ordered)
                    self.assertTrue(verified.stdout.startswith(b"Chain verification succeeded:"))
                    print(verified.stdout.decode().strip())

    def test_higher_cost_arrival_can_save_a_step(self):
        source, detour, middle, target = b"s", b"d", b"m", b"t"
        self.write("installed.bin", source)
        first = self.edge("detour.json", source, detour, 0)
        second = self.edge("join.json", detour, middle, 0)
        short = self.edge("short.json", source, middle, 5)
        same = self.edge("same.json", source, middle, 5)
        finish = self.edge("finish.json", middle, target, 1)
        back = self.edge("back.json", middle, detour, 0)
        loop = self.edge("loop.json", middle, middle, 0)
        direct = self.edge("tie-direct.json", source, target, 6)
        tail = (first, second, finish, back, loop)
        for limit, candidates, cost, expected in [
            ("2", (short, same, *tail), "6", [short, finish]),
            ("2", (same, short, *tail), "6", [same, finish]),
            ("2", (short, same, *tail, direct), "6", [direct]),
            ("9223372036854775807", (short, same, *tail), "1", [first, second, finish]),
        ]:
            with self.subTest(limit=limit, expected=expected):
                plan = json.loads(self.plan(finish, *candidates, options=("--max-steps", limit)).stdout)
                self.assertEqual(plan["total_patch_bytes"], cost)
                self.assertEqual([step["manifest_path"] for step in plan["steps"]], expected)
                print(f"Limit {limit}: {expected}, {cost} bytes")

    def test_unreachable_and_empty_with_step_limit(self):
        _, _, target = prepare_two_hop(self.write, self.invoke)
        edges = ("v1-to-v2.json", "v2-to-v3.json")
        error = self.plan(edges[1], *edges, code=1, options=("--max-steps", "1"))
        self.assertIn(b"no reachable path", error.stderr)
        self.assertIn(b"effective --max-steps=1", error.stderr)
        self.assertIn(b"v2-to-v3.json", error.stderr)
        print(error.stderr.decode().strip())
        for value in ("0", "9223372036854775808", "1KiB"):
            with self.subTest(value=value):
                error = self.plan(edges[1], *edges, code=2, options=("--max-steps", value))
                self.assertIn(b"--max-steps", error.stderr)
        self.assertIn(b"--max-steps", self.invoke(
            "manifest", "select", "--max-steps", "1", "installed.bin", edges[0], code=2
        ).stderr)
        self.write("installed.bin", target)
        self.assertEqual(json.loads(self.plan(edges[1], options=("--max-steps", "1")).stdout), {
            "schema_version": 1, "start": identity(target), "target": identity(target),
            "total_patch_bytes": "0", "steps": [],
        })


class ManifestUpdatePlan(ManifestPlanFixture):
    def test_allow_full_decisions_and_preflight(self):
        _, _, target = prepare_two_hop(self.write, self.invoke)
        prepare_direct(self.write, self.invoke, target)
        candidates = ("v1-to-v2.json", "v2-to-v3.json", "v1-to-v3.json")
        marker = candidates[1]
        one = ("--max-steps", "1", "--")
        two = ("--max-steps", "2", "--")
        legacy = json.loads(self.plan(marker, *candidates, options=one).stdout)
        self.assertEqual(set(legacy), {"schema_version", "start", "target", "total_patch_bytes", "steps"})
        self.assertEqual(legacy["total_patch_bytes"], "2532")
        self.assertEqual([step["manifest_path"] for step in legacy["steps"]], [candidates[2]])
        target_identity = identity(target)
        common = {"schema_version": 1, "start": legacy["start"], "target": target_identity}
        full = {**common, "strategy": "full-file", "download_bytes": "2048"}
        self.assertEqual(json.loads(self.plan(marker, *candidates, options=("--allow-full", *one)).stdout), full)
        self.assertEqual(json.loads(self.plan(marker, options=("--allow-full",)).stdout), full)

        route = json.loads(self.plan(marker, *candidates, options=two).stdout)
        patches = json.loads(self.plan(marker, *candidates, options=("--allow-full", *two)).stdout)
        self.assertEqual(patches, {**common, "strategy": "patches", "download_bytes": "368", "steps": route["steps"]})
        self.assertEqual([step["manifest_path"] for step in patches["steps"]], list(candidates[:2]))

        self.write("broken.json", b"{")
        error = self.plan(marker, *candidates, "broken.json", code=1, options=("--allow-full", *one))
        self.assertIn(b"'broken.json': manifest JSON:", error.stderr)
        self.assertIn(b"--allow-full", self.invoke(
            "manifest", "select", "--allow-full", "installed.bin", marker, code=2
        ).stderr)
        self.write("installed.bin", target)
        current = json.loads(self.plan(marker, options=("--allow-full", *one)).stdout)
        self.assertEqual(current, {**common, "start": target_identity, "strategy": "already-current", "download_bytes": "0"})
        print(f"Patch-only one step: {legacy['total_patch_bytes']} bytes")
        print(json.dumps(full))
        print(f"Two-step strategy: {patches['strategy']}, {patches['download_bytes']} bytes")


def captured_manifest(old, new, patch):
    return {
        "schema_version": 1,
        "patch_format": "BSDIFF40",
        "producer": {"name": "moonbsdiff", "version": version()},
        "old": identity(old),
        "new": identity(new),
        "patch": patch,
    }


def fixed_full_target():
    middle = (UPSTREAM / "new.bin").read_bytes()
    target = middle[:-1] + bytes([middle[-1] ^ 1])
    manifest = captured_manifest(middle, target, {
        "size_bytes": "164",
        "sha256": "3470eb1ac7e7d52c7402d5ee6d142132760e079ba524f8aca8f3bf279959e57e",
    })
    return middle, target, manifest


def fixed_plan_edges(start, middle, target, marker):
    return {
        "v1-to-v2.json": captured_manifest(start, middle, identity((UPSTREAM / "patch.bin").read_bytes())),
        "v2-to-v3.json": marker,
        "v1-to-v3.json": captured_manifest(start, target, {
            "size_bytes": "2532",
            "sha256": "d427a8a80e0bef54802556d0b2db9af2f34f6679597d25d4a45fa9f87005d4e0",
        }),
    }


class InstallFull(ManifestPlanFixture):
    def setUp(self):
        super().setUp()
        _, self.target, self.manifest = fixed_full_target()
        self.write("downloaded-v3.bin", self.target)
        self.write_manifest()

    def write_manifest(self):
        self.write("v2-to-v3.json", json.dumps(self.manifest).encode())

    def install(self, output="restored.bin", code=0, options=()):
        return self.invoke("install-full", "--target-manifest", "v2-to-v3.json",
                           *options, "--", "downloaded-v3.bin", output, code=code)

    def test_installs_the_complete_target(self):
        result = self.install()
        self.assertEqual(result.stdout, b"")
        self.assertEqual(self.read("restored.bin"), self.target)
        self.assertEqual(self.read("downloaded-v3.bin"), self.target)
        actual = identity(self.read("restored.bin"))
        self.assertEqual(actual["size_bytes"], "2048")
        self.assertEqual(actual["sha256"], "66da6542f8276608790055ac88e6af6bf3af76b88bf3aedbcb517c2ce98ab1a6")
        print(f"Installed {actual['size_bytes']} bytes, SHA-256 {actual['sha256']}; source preserved")

    def test_rejects_wrong_content_and_length_and_accepts_empty(self):
        for data, diagnostic in [
            (self.target[:-1] + bytes([self.target[-1] ^ 1]), b"downloaded file sha256 mismatch"),
            (self.target + b"!", b"downloaded file size mismatch"),
            (self.target[:-1], b"downloaded file size mismatch"),
        ]:
            with self.subTest(size=len(data), diagnostic=diagnostic):
                self.write("downloaded-v3.bin", data)
                before = set(self.folder.iterdir())
                error = self.install(code=1)
                self.assertIn(diagnostic, error.stderr)
                self.assertEqual(set(self.folder.iterdir()), before)
                self.assertEqual(self.read("downloaded-v3.bin"), data)
                print(error.stderr.decode().strip())
        empty_patch = ROOT / "testdata/upstream/both-empty/patch.bin"
        self.manifest.update(old=identity(b""), new=identity(b""), patch=identity(empty_patch.read_bytes()))
        self.write_manifest()
        self.write("downloaded-v3.bin", b"")
        self.install()
        self.assertEqual(self.read("restored.bin"), b"")

    def test_preflights_limits_and_preserves_existing_targets(self):
        for cap in ("--max-new-bytes", "--max-output-bytes"):
            error = self.install(code=1, options=(cap, "2047"))
            self.assertIn(cap[2:].replace("-", "_").encode(), error.stderr)
            self.assertFalse((self.folder / "restored.bin").exists())
        self.manifest["patch"]["size_bytes"] = "131073"
        self.write_manifest()
        self.install("allowed.bin", options=("--max-new-bytes", "2048", "--max-output-bytes", "2048"))
        self.assertEqual(self.read("allowed.bin"), self.target)

        self.write("restored.bin", b"competitor")
        self.assertIn(b"output already exists", self.install(code=1).stderr)
        self.assertEqual(self.read("restored.bin"), b"competitor")
        alias = self.folder / "hard-link.bin"
        alias.hardlink_to(self.folder / "downloaded-v3.bin")
        for output in (alias.name, "downloaded-v3.bin"):
            self.assertIn(b"same file as an input", self.install(output, code=1).stderr)
            self.assertEqual(self.read(output), self.target)
        self.manifest["patch"]["sha256"] = "invalid"
        self.write_manifest()
        self.assertIn(b"manifest sha256: patch", self.install("invalid.bin", code=1).stderr)
        self.assertFalse((self.folder / "invalid.bin").exists())
        self.assertIn(b"requires --target-manifest", self.invoke(
            "install-full", "downloaded-v3.bin", "unused.bin", code=2
        ).stderr)
        print("Existing destination and source aliases were preserved")


class ManifestPlanFullLimits(ManifestPlanFixture):
    def setUp(self):
        super().setUp()
        self.middle, self.target, self.marker = fixed_full_target()
        self.write("v2-to-v3.json", json.dumps(self.marker).encode())
        self.write("installed.bin", self.middle)

    def test_target_with_over_budget_patch_is_still_installable(self):
        marker = "v2-to-v3.json"
        budget = ("--max-patch-bytes", "163")
        raw = self.plan(marker, marker, options=("--allow-full", *budget)).stdout
        plan = json.loads(raw)
        self.assertEqual(plan, {
            "schema_version": 1,
            "start": identity(self.middle),
            "target": {
                "size_bytes": "2048",
                "sha256": "66da6542f8276608790055ac88e6af6bf3af76b88bf3aedbcb517c2ce98ab1a6",
            },
            "strategy": "full-file",
            "download_bytes": "2048",
        })
        strict = self.plan(marker, marker, code=1, options=budget)
        self.assertIn(b"patch/max_patch_bytes declared size 164 exceeds limit 163", strict.stderr)
        print(raw.decode().strip())

    def test_filtered_edges_preserve_original_paths_and_order(self):
        start = (UPSTREAM / "old.bin").read_bytes()
        self.write("installed.bin", start)
        edges = fixed_plan_edges(start, self.middle, self.target, self.marker)
        for path, candidate in edges.items():
            self.write(path, json.dumps(candidate).encode())
        self.write("parallel.json", self.read("v1-to-v2.json"))
        edge_paths = ("v1-to-v2.json", "v2-to-v3.json")
        expected_steps = [
            {"manifest_path": path, **{key: edges[path][key] for key in ("old", "new", "patch")}}
            for path in edge_paths
        ]
        eligible = self.plan(edge_paths[1], "v1-to-v3.json", edge_paths[0], "parallel.json",
                             edge_paths[1], options=("--allow-full", "--max-patch-bytes", "204", "--"))
        plan = json.loads(eligible.stdout)
        self.assertEqual(plan["strategy"], "patches")
        self.assertEqual(plan["download_bytes"], "368")
        self.assertEqual(plan["target"], identity(self.target))
        self.assertEqual(plan["steps"], expected_steps)
        print(f"Filtered plan: {[step['manifest_path'] for step in plan['steps']]}, {plan['download_bytes']} bytes")

        tight = self.plan(edge_paths[1], *edge_paths, "v1-to-v3.json",
                          options=("--allow-full", "--max-patch-bytes", "200", "--"))
        plan = json.loads(tight.stdout)
        self.assertEqual((plan["strategy"], plan["download_bytes"]), ("full-file", "2048"))

    def test_invalid_and_oversized_manifests_do_not_fall_back(self):
        marker = "v2-to-v3.json"
        broken = json.loads(self.read(marker))
        broken["patch"] = {"size_bytes": "131073", "sha256": "invalid"}
        self.write("broken.json", json.dumps(broken).encode())
        self.write("too-large.json", b" " * 16385)
        options = ("--allow-full", "--max-patch-bytes", "163")
        for path, diagnostic in [
            ("broken.json", b"manifest sha256: patch requires 64 lowercase hex digits"),
            ("too-large.json", b"16384"),
            ("missing.json", b"read"),
        ]:
            error = self.plan(marker, marker, path, code=1, options=options)
            self.assertIn(f"'{path}'".encode(), error.stderr)
            self.assertIn(diagnostic, error.stderr)
            print(error.stderr.decode().strip())

        error = self.plan(marker, marker, code=1, options=(*options, "--max-output-bytes", "2047"))
        self.assertIn(b"'v2-to-v3.json'", error.stderr)
        self.assertIn(b"new/max_output_bytes declared size 2048 exceeds limit 2047", error.stderr)
        error = self.plan(marker, marker, code=1, options=(*options, "--max-old-bytes", "2047"))
        self.assertIn(b"read old (max_old_bytes=2047 bytes) 'installed.bin'", error.stderr)


class ManifestPlanDownloadBudget(ManifestPlanFixture):
    def setUp(self):
        super().setUp()
        middle, self.target, marker = fixed_full_target()
        start = (UPSTREAM / "old.bin").read_bytes()
        self.write("installed.bin", start)
        edges = fixed_plan_edges(start, middle, self.target, marker)
        for path, candidate in edges.items():
            self.write(path, json.dumps(candidate).encode())
        self.marker = "v2-to-v3.json"
        self.steps = ("v1-to-v2.json", self.marker)
        self.candidates = tuple(edges)

    def test_patch_routes_at_the_budget_boundary(self):
        for flags, candidates, field in [
            ((), self.steps, "total_patch_bytes"),
            (("--allow-full",), self.candidates, "download_bytes"),
        ]:
            with self.subTest(allow_full=bool(flags)):
                options = (*flags, "--max-patch-bytes", "204", "--max-download-bytes")
                raw = self.plan(self.marker, *candidates, options=(*options, "368", "--")).stdout
                plan = json.loads(raw)
                self.assertEqual(plan[field], "368")
                self.assertEqual([step["manifest_path"] for step in plan["steps"]], list(self.steps))
                self.assertEqual([step["patch"]["size_bytes"] for step in plan["steps"]], ["204", "164"])
                if flags:
                    self.assertEqual(plan["strategy"], "patches")
                error = self.plan(self.marker, *candidates, code=1, options=(*options, "367", "--"))
                self.assertIn(b"minimum download 368 bytes exceeds budget 367 bytes", error.stderr)
                print(error.stderr.decode().strip())

    def test_full_file_at_the_budget_boundary(self):
        options = ("--allow-full", "--max-patch-bytes", "200", "--max-download-bytes")
        raw = self.plan(self.marker, *self.candidates, options=(*options, "2KiB")).stdout
        plan = json.loads(raw)
        self.assertEqual(plan["strategy"], "full-file")
        self.assertEqual(plan["download_bytes"], "2048")
        self.assertEqual(plan["target"], identity(self.target))
        error = self.plan(self.marker, *self.candidates, code=1, options=(*options, "2047"))
        self.assertIn(b"minimum download 2048 bytes exceeds budget 2047 bytes", error.stderr)
        print(error.stderr.decode().strip())

    def test_zero_int64_and_invalid_budgets(self):
        flag = "--max-download-bytes"
        wide = self.plan(self.marker, *self.steps, options=(flag, "2147483648B")).stdout
        self.assertEqual(json.loads(wide)["total_patch_bytes"], "368")
        for value in ("-1", "1KB", "9223372036854775808", "8796093022208MiB"):
            with self.subTest(value=value):
                error = self.plan(self.marker, *self.steps, code=2, options=(flag, value))
                self.assertIn(flag.encode(), error.stderr)
        duplicate = self.plan(self.marker, code=2, options=(flag, "0", flag, "1"))
        self.assertIn(b"duplicate option", duplicate.stderr)
        self.assertIn(flag.encode(), self.invoke(
            "manifest", "select", flag, "0", "installed.bin", self.marker, code=2
        ).stderr)
        error = self.plan(self.marker, code=1, options=(flag, "0"))
        self.assertIn(b"no reachable path", error.stderr)
        self.assertNotIn(b"minimum download", error.stderr)

        self.write("installed.bin", self.target)
        for flags, field in [((), "total_patch_bytes"), (("--allow-full",), "download_bytes")]:
            raw = self.plan(self.marker, options=(*flags, flag, "0")).stdout
            plan = json.loads(raw)
            self.assertEqual(plan[field], "0")
            if flags:
                self.assertEqual(plan["strategy"], "already-current")
            else:
                self.assertEqual(plan["steps"], [])
        self.write("bad.json", b"{")
        error = self.plan(self.marker, "bad.json", code=1, options=("--allow-full", flag, "0"))
        self.assertIn(b"'bad.json': manifest JSON:", error.stderr)
        print("Already current: accepted a zero-byte download budget")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--steps-only", action="store_true")
    args = parser.parse_args()
    EXE = args.exe.resolve(strict=True)
    loader = unittest.defaultTestLoader
    tests = loader.loadTestsFromTestCase(ManifestPlanStepLimit)
    if not args.steps_only:
        tests.addTests(loader.loadTestsFromTestCase(ManifestPlan))
        tests.addTests(loader.loadTestsFromTestCase(ManifestUpdatePlan))
        tests.addTests(loader.loadTestsFromTestCase(InstallFull))
        tests.addTests(loader.loadTestsFromTestCase(ManifestPlanFullLimits))
        tests.addTests(loader.loadTestsFromTestCase(ManifestPlanDownloadBudget))
    result = unittest.TextTestRunner(verbosity=2).run(tests)
    if not result.wasSuccessful() or result.testsRun != (3 if args.steps_only else 16) or result.skipped:
        raise SystemExit(1)
