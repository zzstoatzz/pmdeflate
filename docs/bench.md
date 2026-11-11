# bench

pmdeflate against zlib 1.3.2, both built ReleaseFast, on one machine. each of
7 trials runs every configuration once, in alternating order; the median and
the min–max across trials are shown. every payload is decoded by the codec
that made it and compared to the message before its time counts. reproduce
with `zig build bench -- --frames <path> --trials 7 --out <dir>`, or on
spindle with `tg pipeline trigger main -w bench.yml`.

## current decoder, spindle microVM

pmdeflate `b8dc426`, which decodes with its own table-driven inflater.
spindle's 2-vCPU x86_64 microVM (raptorlake), Zig 0.17.0, 2026-11-10, run
`3mzyzvzllr222`. the generated corpus (`test/corpus.zig`: 376 messages,
1.25 MB, heavy in incompressible noise and long runs; sha256 prefix
`c228f57bdfbf1714`), since the relay frames are not in the repository.

| codec | level | takeover | payload / raw | encode MB/s | decode MB/s | heap per connection |
|---|---:|---|---:|---:|---:|---:|
| pmdeflate | 1 | on | 0.5251 | 89.5 (89.1–92.1) | 373.1 (360.0–386.0) | 365 KiB |
| zlib | 1 | on | 0.5225 | 101.2 (100.5–102.1) | 695.8 (668.0–718.9) | ~422 KiB |
| pmdeflate | 6 | on | 0.5192 | 84.7 (84.2–85.4) | 388.3 (384.5–395.2) | 365 KiB |
| zlib | 6 | on | 0.5163 | 83.1 (82.7–84.2) | 586.2 (548.6–599.1) | ~422 KiB |
| pmdeflate | 6 | off | 0.5575 | 85.2 (84.3–87.0) | 363.6 (360.4–366.0) | 365 KiB |
| zlib | 6 | off | 0.5564 | 92.0 (91.2–94.8) | 711.1 (704.8–715.7) | ~422 KiB |

## reading it

- compression ratio is within 0.6% of zlib at every configuration.
- decoding is 0.51–0.66x zlib on the spindle VM. it is not at parity: zlib's
  hand-tuned inflate is faster still, most of all on stored blocks and long
  runs, which this corpus is heavy in.
- on the 3,160 relay frames below, a paired laptop run of the current decoder
  measured 0.74–0.88x zlib, but other processes held the laptop at a load
  average near 5 (zlib's own encode fell a third against the idle run), so
  treat that ratio as indicative and the absolute numbers as unusable.
- encoding is unchanged by the decoder work: on relay frames it was 9–25%
  faster than zlib; on the generated corpus it is level with zlib at level 6
  and 10–12% slower at level 1.
- heap is pmdeflate's measured allocation for one deflater and one inflater
  after one message. zlib allocates through malloc, so its figure is the
  documented state size (deflate 384 KiB at windowBits 15, memLevel 8;
  inflate 32 KiB) plus this harness's buffer, an estimate rather than a
  measurement. the inflater keeps up to 128 KiB of history before it moves
  the last window to the front.

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
