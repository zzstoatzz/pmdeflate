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

fixed before the first commit: the decoder never writes past the remaining
room. the regression is in `src/rfc7692_test.zig`, and `mutants.zon`
re-plants the bug as `finding: a refused message writes one byte past max_len`.

## a payload that ends mid-block is accepted, filled from the receiver's tail

the inflater appended `00 00 ff ff`, then a final empty stored block, so
the decoder would stop on its own. a payload whose last stored block claims
more bytes than it carries read that appended block as its data: `01 09 00
f6 ff` (a final stored block of 9 bytes with none) decoded to 9 bytes the
peer never sent. zlib refuses it.

found by an adversarial review of `3d6c0bb`, not by the campaign: random
payloads rarely shape a stored length to reach exactly into the tail. fixed
by reading the payload in place with only the RFC's `00 00 ff ff` after it,
and accepting only input consumed exactly at a block boundary. the
regression is in `src/review_test.zig`.

## a peer's largest payload stays allocated

the inflater copied every payload into a buffer it never shrank, and kept
its output buffer's capacity across `reset` and failed messages. one 4 MiB
frame left about 6 MB allocated on an idle connection, whatever `max_len`
was. found by the same review. the payload is no longer copied, and output
capacity past 256 KiB is returned after each message and on `reset`; the
regressions measure live heap bytes in `src/review_test.zig`.
