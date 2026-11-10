# pmdeflate property campaign

Native Hegel revision: `4b2bc83a5750bb872524bb97ccb0f6c45a1c3d24`. Oracle:
zlib 1.3.2. Zig 0.17.0.

```sh
HEGEL_SEED=1 HEGEL_TEST_CASES=300 zig build pbt     # every property
HEGEL_TEST_CASES=2000 zig build pbt                 # a longer exploration
HEGEL_TEST_CASES=300 zig build mutants              # in a disposable worktree
```

`zig build mutants` plants each entry of `mutants.zon` in turn and runs the
campaign under ten seeds; it edits sources, so run it in a disposable
worktree. Entries prefixed `finding:` undo a fix recorded in
[findings.md](findings.md).

Replay a failure with `HEGEL_ZIG_REPLAY` and the same executable, target,
dependency revision and generator; a seed does not replace the blob once the
generator changes. `HEGEL_ZIG_ECHO=1` prints the history before a panic.

| Surface | Current checks | Remaining work |
| --- | --- | --- |
| Deflater | every payload decodes to the message in pmdeflate and zlib, levels 1–9, takeover on and off, resets, messages past the window and exactly one window back | allocation failure paths |
| Inflater | zlib payloads at levels 1–9; payloads ending in or continuing past a BFINAL block; a window kept across messages and resets | payloads from encoders other than zlib and pmdeflate |
| Malformed input | flipped bits, truncation, appended and spliced noise, replaced payloads: refused or bounded by the limit, agreement with zlib when both accept, poisoning after a refusal | dynamic-Huffman table corruption is reached only by chance |
| Limits | output never passes `max_len`; a message of exactly `max_len` is accepted | |

The table describes what the campaign checks, not exhaustive coverage.
