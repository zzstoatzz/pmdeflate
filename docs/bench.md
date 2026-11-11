# bench

pmdeflate against zlib 1.3.2, both built ReleaseFast, on one machine. each of
7 trials runs every configuration once, in alternating order; the median and
the min–max across trials are shown. every payload is decoded by the codec
that made it and compared to the message before its time counts. reproduce
with `zig build bench -- --frames <path> --trials 7 --out <dir>`, or on
spindle with `tg pipeline trigger main -w bench.yml`.

## current decoder, spindle microVM

pmdeflate v0.1.0 (`97dff33`), which decodes with its own table-driven
inflater, reading each payload in place. spindle's 2-vCPU x86_64 microVM
(raptorlake), Zig 0.17.0, 2026-11-11, run `3n22iaswuii22`. the generated
corpus (`test/corpus.zig`: 376 messages, 1.25 MB, heavy in incompressible
noise and long runs; sha256 prefix `c228f57bdfbf1714`), since the relay frames
are not in the repository.

| codec | level | takeover | payload / raw | encode MB/s | decode MB/s | heap per connection |
|---|---:|---|---:|---:|---:|---:|
| pmdeflate | 1 | on | 0.5251 | 83.5 (77.6–84.6) | 353.9 (334.5–369.9) | 364 KiB |
| zlib | 1 | on | 0.5225 | 92.4 (88.9–96.4) | 692.5 (655.7–735.8) | ~422 KiB |
| pmdeflate | 6 | on | 0.5192 | 75.3 (73.4–80.3) | 365.5 (357.4–388.9) | 364 KiB |
| zlib | 6 | on | 0.5163 | 74.3 (72.3–79.2) | 579.2 (562.0–606.2) | ~422 KiB |
| pmdeflate | 6 | off | 0.5575 | 77.7 (74.4–81.5) | 348.3 (338.6–375.4) | 364 KiB |
| zlib | 6 | off | 0.5564 | 82.4 (80.2–88.4) | 718.0 (671.5–750.2) | ~422 KiB |

## reading it

- compression ratio is within 0.6% of zlib at every configuration.
- decoding is 0.49–0.63x zlib on the spindle VM. it is not at parity: zlib's
  hand-tuned inflate is faster still, most of all on stored blocks and long
  runs, which this corpus is heavy in.
- against `b8dc426` (run `3mzyzvzllr222`, 2026-11-10), which copied each
  payload before decoding, pmdeflate's decode is 4–6% lower while zlib's moved
  1% or less, so reading in place likely costs that much. it is one run each.
- on the 3,160 relay frames below, a paired laptop run of the current decoder
  measured 0.74–0.88x zlib, but other processes held the laptop at a load
  average near 5 (zlib's own encode fell a third against the idle run), so
  treat that ratio as indicative and the absolute numbers as unusable.
- encoding is unchanged by the decoder work: on relay frames it was 9–25%
  faster than zlib; on the generated corpus it is level with zlib at level 6
  with takeover, 6% slower without it, and 10% slower at level 1.
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
