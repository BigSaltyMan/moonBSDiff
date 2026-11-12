// Private real-file IO fault points; no CLI/environment switch enables them.

///|
extern "C" fn io_contract(mode : Int32) -> Int32 = "mbsd_io_contract"

///|
test "native-io-exclusive-collision" {
  assert_eq(io_contract(1), 0)
}

///|
test "native-io-target-race" {
  assert_eq(io_contract(2), 0)
}

///|
test "native-io-read-growth" {
  assert_eq(io_contract(3), 0)
}

///|
test "native-io-partial-write-error" {
  assert_eq(io_contract(4), 0)
}

///|
test "native-io-write-close-error" {
  assert_eq(io_contract(5), 0)
}

///|
test "native-io-delivery-error" {
  assert_eq(io_contract(6), 0)
}

///|
test "native-io-read-close-error" {
  assert_eq(io_contract(7), 0)
}

///|
test "native-io-unknown-size-limit" {
  assert_eq(io_contract(8), 0)
}

///|
test "native-io-short-writes" {
  assert_eq(io_contract(9), 0)
}
