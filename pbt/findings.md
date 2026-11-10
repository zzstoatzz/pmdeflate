# findings

## a refused message writes one byte past `max_len`

`Inflater.decompress` promises to write at most `max_len` bytes. it asked
the decoder for `room + 1` bytes to detect an oversized message, so a
refused message could leave `max_len + 1` bytes in the caller's writer.

found by the corrupted-payloads property on its first run, at 100 cases:
a replaced 3-byte payload with a small limit.

```sh
HEGEL_ZIG_REPLAY=AXic42AAAi5GEMkIZbBA+SgUCzMziAkXBQALiwBk zig build pbt
```

the blob was recorded against the generator before the window-edge and
BFINAL shapes were added, so it does not replay against the committed
generator; the regression test and the `finding:` mutant carry the case.

fixed before the first commit: the decoder writes at most the remaining
room, and a one-byte probe decides whether more output exists. the
regression is in `src/rfc7692_test.zig`, and `mutants.zon` re-plants the
bug as `finding: a refused message writes one byte past max_len`.
