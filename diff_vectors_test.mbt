// Generated from testdata/upstream/manifest.json by scripts/check_diff.py.

///|
test "diff-upstream-both-empty" {
  diff_test_run("both-empty", apply_fixture_0_old(), apply_fixture_0_new())
}

///|
test "diff-upstream-old-empty" {
  diff_test_run("old-empty", apply_fixture_1_old(), apply_fixture_1_new())
}

///|
test "diff-upstream-new-empty" {
  diff_test_run("new-empty", apply_fixture_2_old(), apply_fixture_2_new())
}

///|
test "diff-upstream-identical" {
  diff_test_run("identical", apply_fixture_3_old(), apply_fixture_3_new())
}

///|
test "diff-upstream-replace" {
  diff_test_run("replace", apply_fixture_4_old(), apply_fixture_4_new())
}

///|
test "diff-upstream-insert" {
  diff_test_run("insert", apply_fixture_5_old(), apply_fixture_5_new())
}

///|
test "diff-upstream-delete" {
  diff_test_run("delete", apply_fixture_6_old(), apply_fixture_6_new())
}

///|
test "diff-upstream-prepend" {
  diff_test_run("prepend", apply_fixture_7_old(), apply_fixture_7_new())
}

///|
test "diff-upstream-append" {
  diff_test_run("append", apply_fixture_8_old(), apply_fixture_8_new())
}

///|
test "diff-upstream-all-bytes" {
  diff_test_run("all-bytes", apply_fixture_9_old(), apply_fixture_9_new())
}

///|
test "diff-upstream-periodic" {
  diff_test_run("periodic", apply_fixture_10_old(), apply_fixture_10_new())
}

///|
test "diff-upstream-block-move" {
  diff_test_run("block-move", apply_fixture_11_old(), apply_fixture_11_new())
}

///|
test "diff-upstream-seeded-random" {
  diff_test_run("seeded-random", apply_fixture_12_old(), apply_fixture_12_new())
}
