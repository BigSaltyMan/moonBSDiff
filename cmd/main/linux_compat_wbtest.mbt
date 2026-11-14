// Linux only: no Windows no-op passes or product switches.

///|
#cfg(not(platform="windows"))
extern "C" fn compat_contract(mode : Int32) -> Int32 = "mbsd_compat_contract"

///|
#cfg(not(platform="windows"))
test "linux-compat-success-collision-target-and-proc-capability" {
  for mode in [1, 2, 3, 10, 12, 14] {
    assert_eq(compat_contract(mode), 0)
  }
}

///|
#cfg(not(platform="windows"))
test "linux-compat-identity-cleanup-and-no-error-retry" {
  for mode in [4, 5, 6, 7, 8, 9, 11, 13, 15, 16, 17, 18] {
    assert_eq(compat_contract(mode), 0)
  }
}
