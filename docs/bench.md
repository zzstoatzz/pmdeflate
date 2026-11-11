# bench

pmdeflate against zlib 1.3.2, both built ReleaseFast, on one machine. each of
9 trials runs every configuration once, in alternating order; the median and
the min–max across trials are shown. every payload is decoded by the codec
that made it and compared to the message before its time counts. zlib decodes
through `StreamInflater` in `test/zlib.zig`, which feeds the payload and the
RFC 7692 tail as two inputs and keeps zlib's own window, as a production codec
does. reproduce with `zig build bench -- --frames <path> --trials 9`.

## current decoder, dedicated core

pmdeflate `7b92c64`. one Fly `performance-1x` machine in iad (a dedicated AMD
EPYC core, 2 GB), Zig 0.17.0, x86_64-linux, 2026-11-11, created for the run
and destroyed after it. a second machine running the same image gave decode
ratios within 0.1 of these.

relay frames: 3,160 `com.atproto.sync.subscribeRepos` frames (16.9 MB, mean
5.4 KB), atproto-bench's `fixtures/firehose-frames.bin`, sha256 prefix
`40986f3c9dadb7f9`. this is what a relay sends a subscriber.

| codec | level | takeover | payload / raw | encode MB/s | decode MB/s | heap per connection |
|---|---:|---|---:|---:|---:|---:|
| pmdeflate | 1 | on | 0.6707 | 39.3 (37.5–39.9) | 297.9 (286.3–301.5) | 364 KiB |
| zlib | 1 | on | 0.6729 | 40.4 (38.7–41.0) | 224.7 (219.3–229.2) | ~422 KiB |
| pmdeflate | 6 | on | 0.6530 | 28.8 (28.3–29.4) | 309.9 (298.5–312.3) | 364 KiB |
| zlib | 6 | on | 0.6511 | 25.7 (25.3–25.9) | 242.6 (232.7–246.0) | ~422 KiB |
| pmdeflate | 6 | off | 0.7055 | 46.4 (45.8–47.5) | 299.4 (292.9–300.8) | 364 KiB |
| zlib | 6 | off | 0.7050 | 42.0 (41.4–42.4) | 229.5 (224.1–236.9) | ~422 KiB |

the generated corpus (`test/corpus.zig`: 376 messages, 1.25 MB, heavy in
incompressible noise and long runs; sha256 prefix `c228f57bdfbf1714`):

| codec | level | takeover | payload / raw | encode MB/s | decode MB/s | heap per connection |
|---|---:|---|---:|---:|---:|---:|
| pmdeflate | 1 | on | 0.5251 | 57.0 (54.1–58.6) | 378.7 (334.3–386.3) | 364 KiB |
| zlib | 1 | on | 0.5225 | 70.0 (57.7–71.4) | 978.9 (881.1–1003.9) | ~422 KiB |
| pmdeflate | 6 | on | 0.5192 | 52.5 (49.2–55.1) | 415.6 (384.3–421.5) | 364 KiB |
| zlib | 6 | on | 0.5163 | 55.5 (52.8–56.6) | 625.1 (557.3–636.8) | ~422 KiB |
| pmdeflate | 6 | off | 0.5575 | 57.1 (53.4–58.2) | 379.3 (359.9–389.3) | 364 KiB |
| zlib | 6 | off | 0.5564 | 59.8 (50.6–61.0) | 512.3 (502.7–515.7) | ~422 KiB |

## reading it

- on relay frames, decoding is 1.28–1.33x zlib, and 1.19–1.25x on the second
  machine. on the generated corpus it is 0.39–0.74x: zlib is faster on stored
  blocks and long runs, which that corpus is made of.
- v0.1.0's decoder, on another machine of the same size the same day, decoded
  relay frames at 0.69–0.73x zlib and the generated corpus at 0.20–0.39x. the
  fast loop, which takes up to two literals per refill and copies matches by
  word, made decoding 1.7x faster on relay frames and 1.9x on the generated
  corpus.
- compression ratio is within 0.6% of zlib at every configuration. encoding is
  0.97–1.12x zlib on relay frames and 0.81–0.95x on the generated corpus.
- heap is pmdeflate's measured allocation for one deflater and one inflater
  after one message. zlib allocates through malloc, so its figure is the
  documented state size (deflate 384 KiB at windowBits 15, memLevel 8;
  inflate 32 KiB) plus this harness's buffer, an estimate rather than a
  measurement. the inflater keeps up to 128 KiB of history before it moves
  the last window to the front.
- until `7b92c64` the bench decoded zlib through the test oracle, which
  rebuilds a 32 KiB history after every message to continue past BFINAL
  blocks. that slowed zlib most on small messages, so earlier ratios,
  including the section below, understate zlib.

## earlier decoder: std's flate.Decompress

pmdeflate `0831d77` decoded through std's `flate.Decompress`. a sampled
profile put 86% of decode time in its core loop, which reads one symbol per
iteration through an `Io.Reader` and writes each literal through a checked
`Writer` call; that is what the table-driven inflater replaced. measured on
an idle Apple M5 Pro, macOS 26.5.1, Zig 0.17.0, 2026-11-10.

relay frames: 3,160 `com.atproto.sync.subscribeRepos` frames (16.9 MB, mean
5.4 KB), atproto-bench's `fixtures/firehose-frames.bin`, sha256 prefix
`40986f3c9dadb7f9`. this is what a relay sends a subscriber.

| codec | level | takeover | payload / raw | encode MB/s | decode MB/s |
|---|---:|---|---:|---:|---:|
| pmdeflate | 1 | on | 0.6707 | 87.6 | 241.2 |
| zlib | 1 | on | 0.6729 | 80.2 | 373.7 |
| pmdeflate | 6 | on | 0.6530 | 66.2 | 250.5 |
| zlib | 6 | on | 0.6511 | 55.2 | 398.5 |
| pmdeflate | 6 | off | 0.7055 | 104.1 | 232.0 |
| zlib | 6 | off | 0.7050 | 83.0 | 379.1 |

on the generated corpus that decoder ran at 0.18–0.34x zlib.
