// Commit 42's fixed planning fixture. The old bytes and first patch come
// from testdata/upstream/seeded-random. The second patch and three manifests
// are from the CLI fixture in scripts/test_cli_manifest_plan.py. Python
// hashlib independently checked the identities before they were captured.

///|
fn plan_fixture_manifest(
  old_hash : String,
  new_hash : String,
  patch_size : Int32,
  patch_hash : String,
) -> Bytes {
  let raw = "{\"schema_version\":1,\"patch_format\":\"BSDIFF40\"," +
    "\"producer\":{\"name\":\"moonbsdiff\",\"version\":\"0.4.0\"}," +
    "\"old\":{\"size_bytes\":\"2048\",\"sha256\":\"\{old_hash}\"}," +
    "\"new\":{\"size_bytes\":\"2048\",\"sha256\":\"\{new_hash}\"}," +
    "\"patch\":{\"size_bytes\":\"\{patch_size}\",\"sha256\":\"\{patch_hash}\"}}"
  @utf8.encode(raw[:])
}

///|
fn plan_fixture_documents() -> Array[Bytes] {
  let old = "3f1dc5983729c3316f87f580ef435e68507120b7bde1a52f15dbbc93169751d8"
  let middle = "ec7c875b594819312410388bd93805e989e4dba1cc68f793ece69352bfe8d6f5"
  let target = "66da6542f8276608790055ac88e6af6bf3af76b88bf3aedbcb517c2ce98ab1a6"
  [
    plan_fixture_manifest(
      old, middle, 204, "b48d5bd790a5a37b507603284b501f21a6c15c110e96c6cabecd1867f705927b",
    ),
    plan_fixture_manifest(
      middle, target, 164, "3470eb1ac7e7d52c7402d5ee6d142132760e079ba524f8aca8f3bf279959e57e",
    ),
    plan_fixture_manifest(
      old, target, 2532, "d427a8a80e0bef54802556d0b2db9af2f34f6679597d25d4a45fa9f87005d4e0",
    ),
  ]
}

///|
fn plan_fixture_candidates() -> Array[@manifest.PreparedManifest] {
  let limits = @moonbsdiff.Limits::for_apply()
  plan_fixture_documents().map(raw => @manifest.prepare(raw, limits).unwrap())
}

///|
fn plan_fixture_old() -> Bytes {
  let encoded = "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"
  @base64.decode(encoded[:]) catch {
    _ => abort("invalid old fixture encoding")
  }
}

///|
fn plan_fixture_patches() -> Array[Bytes] {
  let first = "QlNESUZGNDAxAAAAAAAAAG0AAAAAAAAAAAgAAAAAAABCWmg5MUFZJlNZR2IYPQAAA9BAYlACAEAAIAAxDADTI2pNmIaGg8Xc" +
    "kU4UJBHYhg9AQlpoOTFBWSZTWQ2w5a0AAAL//fAhCAIBCQBAAEAIAgEAAAQAEiAAQAgFFAFEEAAQiSAAIjVAMjIDTGoyeUMY" +
    "TEyYCYABATLCxuAIPb1Plr6Mnfv3XziEDU5Ie2tFr8iZAL+LuSKcKEgG2HLWgEJaaDkXckU4UJAAAAAA"
  let second = "QlNESUZGNDA0AAAAAAAAACsAAAAAAAAAAAgAAAAAAABCWmg5MUFZJlNZX5q9fwAACkBQ+oBAAABAAACgADEAwEaMjItJFUrD" +
    "ic8XckU4UJBfmr1/QlpoOTFBWSZTWe81TMwAAARAAMgAAAggADDMBVHpCjjC7kinChId5qmZgEJaaDkxQVkmU1lFk+DhAAAA" +
    "AAEAAiAAIRhGgu5IpwoSCLJ8HCA="
  [first, second].map(encoded => {
    @base64.decode(encoded[:]) catch {
      _ => abort("invalid patch fixture encoding")
    }
  })
}

///|
fn plan_downloads(
  installed : Bytes,
  target_manifest : Bytes,
  entries : Array[(Bytes, String)],
) -> Result[Array[String], String] {
  let limits = @moonbsdiff.Limits::for_apply()
  let target = match @manifest.prepare(target_manifest, limits) {
    Ok(prepared) => prepared
    Err(error) => return Err(@debug.to_string(error))
  }
  let candidates : Array[@manifest.PreparedManifest] = []
  for (manifest, _) in entries {
    match @manifest.prepare(manifest, limits) {
      Ok(prepared) => candidates.push(prepared)
      Err(error) => return Err(@debug.to_string(error))
    }
  }
  let start = @manifest.ContentIdentity::of_bytes(installed)
  match @manifest.plan(start, target.new, candidates, max_steps=2L) {
    Ok(route) => {
      let downloads : Array[String] = []
      for index in route.candidate_indices {
        let (_, patch_location) = entries[index]
        downloads.push(patch_location)
      }
      Ok(downloads)
    }
    Err(error) => Err(@debug.to_string(error))
  }
}

///|
test "manifest public plan honors one and two steps" {
  let candidates = plan_fixture_candidates()
  let installed = plan_fixture_old()
  let documents = plan_fixture_documents()
  assert_eq(
    plan_downloads(installed, documents[1], [
      (documents[0], "v1-to-v2.patch"),
      (documents[1], "v2-to-v3.patch"),
      (documents[2], "v1-to-v3.patch"),
    ]),
    Ok(["v1-to-v2.patch", "v2-to-v3.patch"]),
  )
  let start = @manifest.ContentIdentity::of_bytes(installed)
  let target = candidates[1].new
  assert_eq(start.size, 2048L)
  assert_eq(
    start.hash,
    "3f1dc5983729c3316f87f580ef435e68507120b7bde1a52f15dbbc93169751d8",
  )
  let direct = @manifest.plan(start, target, candidates, max_steps=1L).unwrap()
  let two = @manifest.plan(start, target, candidates, max_steps=2L).unwrap()
  let unrestricted = @manifest.plan(start, target, candidates).unwrap()
  let direct_indices : ReadOnlyArray[Int32] = [2]
  let two_indices : ReadOnlyArray[Int32] = [0, 1]
  assert_eq(direct.candidate_indices, direct_indices)
  assert_eq(direct.total_patch_bytes, 2532L)
  assert_eq(candidates[direct.candidate_indices[0]].patch.size, 2532L)
  assert_eq(two.candidate_indices, two_indices)
  assert_eq(two.total_patch_bytes, 368L)
  assert_eq(candidates[two.candidate_indices[0]].patch.size, 204L)
  assert_eq(candidates[two.candidate_indices[1]].patch.size, 164L)
  assert_eq(unrestricted.candidate_indices, two_indices)
  assert_eq(unrestricted.total_patch_bytes, two.total_patch_bytes)
  assert_eq(candidates.map(candidate => candidate.patch.size), [
    204L, 164L, 2532L,
  ])
}

///|
test "manifest public plan distinguishes invalid, unreachable and empty" {
  let candidates = plan_fixture_candidates()
  let start = candidates[0].old
  let target = candidates[1].new
  for limit in [0L, -1L] {
    assert_eq(
      @manifest.plan(start, start, [], max_steps=limit).unwrap_err(),
      @manifest.InvalidMaxSteps(limit),
    )
  }
  assert_eq(
    @manifest.plan(start, target, []).unwrap_err(),
    @manifest.NoRoute(effective_max_steps=None),
  )
  assert_eq(
    @manifest.plan(start, target, [candidates[0], candidates[1]], max_steps=1L).unwrap_err(),
    @manifest.NoRoute(effective_max_steps=Some(1L)),
  )
  let empty = @manifest.plan(target, target, [], max_steps=1L).unwrap()
  assert_eq(empty.total_patch_bytes, 0L)
  assert_true(empty.candidate_indices.is_empty())
}

///|
test "manifest plan restores documented 2048-byte route" {
  let candidates = plan_fixture_candidates()
  let installed = plan_fixture_old()
  let patches = plan_fixture_patches()
  let route = @manifest.plan(
    @manifest.ContentIdentity::of_bytes(installed),
    candidates[1].new,
    candidates,
    max_steps=2L,
  ).unwrap()
  let mut current = installed
  for index in route.candidate_indices {
    current = candidates[index].restore(current, patches[index]).unwrap()
  }
  // Independent target: replay the fixture's known 31-byte edit and final bit
  // flip on the original bytes, then compare the full output buffer.
  let expected = installed[:700].to_owned() +
    b"\x08\xd8\x64\x1c\x3b\x51\xaa\xa8\xb2\xca\xa3\x5b\xb9\xe0\xc1\x9c\x9a\xb5\xc6\x5d\xee\x83\x5e\x65\x0d\x56\x4e\x4a\xe6\xe3\x4f" +
    installed[731:2047].to_owned() +
    b"\xed"
  assert_eq(expected.length(), 2048)
  assert_eq(current, expected)
}

///|
test "manifest public update compares patch routes with the full target" {
  let candidates = plan_fixture_candidates()
  let start = @manifest.ContentIdentity::of_bytes(plan_fixture_old())
  let target = candidates[1].new
  match @manifest.plan_update(start, target, candidates, max_steps=1L) {
    Ok(FullFile(identity)) => {
      assert_true(identity == target)
      assert_eq(identity.size, 2048L)
    }
    _ => abort("one-step update must download the full target")
  }
  match @manifest.plan_update(start, target, candidates, max_steps=2L) {
    Ok(Patches(route)) => {
      let expected : ReadOnlyArray[Int32] = [0, 1]
      assert_eq(route.candidate_indices, expected)
      assert_eq(route.total_patch_bytes, 368L)
    }
    _ => abort("two-step update must download the patch route")
  }
}

///|
test "manifest public update handles ties, current targets and invalid limits" {
  let candidates = plan_fixture_candidates()
  let start = candidates[0].old
  let target = candidates[1].new
  // This synthetic edge tests only declared cost. It has the same cost as
  // the complete target and does not need a corresponding patch payload.
  let tied = plan_fixture_manifest(
    start.hash,
    target.hash,
    2048,
    candidates[2].patch.hash,
  )
  let edge = @manifest.prepare(tied, @moonbsdiff.Limits::for_apply()).unwrap()
  for available in [[], [edge]] {
    match @manifest.plan_update(start, target, available, max_steps=1L) {
      Ok(FullFile(identity)) => assert_true(identity == target)
      _ => abort("missing routes and equal costs must favor the full target")
    }
  }
  match @manifest.plan_update(target, target, []) {
    Ok(UpToDate) => ()
    _ => abort("installed target needs no download")
  }
  assert_eq(
    @manifest.plan_update(target, target, [], max_steps=0L).unwrap_err(),
    @manifest.InvalidMaxSteps(0L),
  )
}
