///|
fn main {
  let old = b"old\x00\xff-data"
  let limits = @moonbsdiff.Limits::for_diff()
  let index = match @moonbsdiff.DiffIndex::build(old, limits) {
    Ok(value) => value
    Err(_) => abort("index build failed")
  }
  // Positive configuration remains mandatory, but indexed calls do not sort.
  let per_target = { ..limits, max_sort_work: 1L, }
  for expected in [b"old\x00\xff-DATA!", b"prefix-old\x00\xff-data"] {
    let patch = match index.diff(expected, per_target) {
      Ok(value) => value
      Err(_) => abort("indexed generation failed")
    }
    let restored = match @moonbsdiff.apply(old, patch, limits) {
      Ok(value) => value
      Err(_) => abort("apply failed")
    }
    if restored != expected {
      abort("restored bytes differ from predefined target")
    }
  }
  println("one old index, two restored targets: PASS")
}
