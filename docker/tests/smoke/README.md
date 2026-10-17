# API smoke test

`api-smoke.sh` (task T-023) checks a running stack through the BBB API: create, join
(`redirect=false`), getMeetings, end, isMeetingRunning. `test-api-smoke.sh` and `mock/` are the
protected interface tests: the mock implements just enough of the API and verifies checksums the
way bbb-web does.
