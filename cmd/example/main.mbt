///|
fn main {
  let old = b"MoonBSDiff\x00version 1\xff"
  let expected = b"MoonBSDiff\x00version 2!\xff"
  let patch = match
    @moonbsdiff.diff(old, expected, @moonbsdiff.Limits::for_diff()) {
    Ok(value) => value
    Err(_) => abort("diff failed")
  }
  let restored = match
    @moonbsdiff.apply(old, patch, @moonbsdiff.Limits::for_apply()) {
    Ok(value) => value
    Err(_) => abort("apply failed")
  }
  if restored != expected {
    abort("restored bytes differ from predefined new bytes")
  }
  println("old bytes: \{old.length()}")
  println("new bytes: \{expected.length()}")
  println("patch bytes: \{patch.length()}")
  println("restored bytes equal predefined new bytes: PASS")
}
