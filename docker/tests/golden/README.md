# Golden-file tests

`run-golden.sh` (task T-020) renders each image's configuration with `--render-only` and the
fixture env, and compares it with the committed `expected/` tree; `--parity` also compares with
the bare-metal reference (RB-01) under an allowlist of intended differences, each with a reason.
`test-golden.sh` and `selftest-image/` are the protected interface tests.
