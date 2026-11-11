# changelog

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
