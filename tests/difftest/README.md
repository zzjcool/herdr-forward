# tests/difftest — Go golden contract

Phase 5 removes the Bash implementation and therefore removes the old Bash↔Go
oracle. The contract is still byte-level: `run.sh` executes the final Go CLI on
438 deterministic cases and compares exit code plus stdout with
`tests/difftest/golden.tsv`.

```sh
bash tests/difftest/run.sh
```

The golden file stores `case-id<TAB>exit-code<TAB>base64(stdout)`. Base64 keeps
newlines, Unicode and empty output unambiguous while the comparison remains
byte-for-byte. State fixtures are copied into an isolated temporary state
folder for every case; no user state is read or written.

## Inventory

The 438 cases retain the Phase 4 guardrail categories:

- state load/save and the five committed state fixtures;
- `list` table/JSON/oneline forms;
- HF1 formatting/parsing and malformed input boundaries;
- C6 local/remote port validation, including leading-zero and out-of-range
  literals;
- SSH destination, remote-command quoting, bridge argv and KV parsing;
- panel frame golden output and CLI error boundaries.

The exact inventory is generated in `tests/difftest/run.sh`; the script refuses
to run if its count changes from 438. A maintainer may intentionally refresh
all values with `GOLDEN_UPDATE=1`, but ordinary CI never writes the golden file.
That makes the current Go output a permanent release guard rather than a
self-comparison between two implementations.

`phase2-go-path.sh` and `phase3-go-path.sh` were retired with the Bash
implementation. Their real-SSH and HF1 coverage is retained by the Go
integration/E2E paths (`test_cli_full_cycle.sh`, `test_bridge_roundtrip.sh`,
and `scripts/e2e/run-inside.sh`).
