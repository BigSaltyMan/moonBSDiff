///|
test "manifest-sha256-vectors-and-buffer-binding" {
  assert_eq(
    sha256_hex(b""),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  )
  assert_eq(
    sha256_hex(b"abc"),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  )
  let old = b"\x00\xff"
  let new = b"abc"
  let patch = b"fixed patch buffer"
  let first = make_manifest(old, new, patch)
  assert_eq(first, make_manifest(old, new, patch))
  assert_true(first != make_manifest(new, old, patch))
}
