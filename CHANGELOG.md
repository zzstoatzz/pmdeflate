# changelog

## 0.1.1

- `Inflater` decodes in a fast loop while a whole symbol is safe: one
  branchless refill covers up to two literals or a match with its extra bits,
  and matches copy by word. on a dedicated core it decodes relay frames at
  1.28–1.33x zlib 1.3.2 and the generated corpus at 0.39–0.74x, 1.7x and 1.9x
  faster than 0.1.0. errors and limits are unchanged; see `docs/bench.md`.
- the bench decodes zlib payloads as a production codec does. it used the
  test oracle, which rebuilds a 32 KiB history after every message, so
  0.1.0's published ratios understated zlib.

## 0.1.0

first release. `Deflater` and `Inflater` implement RFC 7692 permessage-deflate
in pure Zig 0.17, with context takeover on or off per direction.

- `Inflater` decodes with its own table-driven inflater, reads each payload in
  place, and accepts it only when it ends exactly at a block boundary. it
  matches zlib's accept and refuse decisions on generated and corrupted
  payloads, and never writes past `max_len`.
- output capacity past 256 KiB is returned after each message and on `reset`;
  `Deflater.trim` returns a grown payload buffer between messages.
- a `Deflater` honors only `max_window_bits=15`.
- builds without libc for Linux, macOS, Windows, FreeBSD, wasm32-freestanding
  and wasm32-wasi.
