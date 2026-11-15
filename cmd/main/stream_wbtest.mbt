///|
extern "C" fn stream_contract(mode : Int32) -> Int32 = "mbsd_stream_contract"

///|
test "stream delivery: callback faults, publication race, cleanup and reuse" {
  for mode in [2, 4, 5, 6, 9, 10] {
    assert_eq(stream_contract(mode), 0)
  }
}

///|
#cfg(not(platform="windows"))
test "stream delivery: guarded compatibility callback" {
  assert_eq(stream_contract(11), 0)
}
