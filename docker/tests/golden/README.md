# Golden-file tests

`run-golden.sh` (task T-020) renders each image's configuration with `--render-only` and the
fixture env, and compares it with the committed `expected/` tree; `--parity` also compares with
the bare-metal reference (RB-01) under an allowlist of intended differences, each with a reason.
`test-golden.sh` and `selftest-image/` are the protected interface tests.

`test-expectations.sh` (protected, task T-044) adds the per-image `expectations.yaml` check: values
that must appear in rendered files, entrypoint failures that must happen (missing variable,
newline in a value), and rendering under an arbitrary UID. Image tasks get their
`expectations.yaml` from the supervisor before they start; the byte-level `expected/` tree and
`parity.yaml` are written by the image task and reviewed.
