# bench

pmdeflate against zlib 1.3.2, both built ReleaseFast, on one machine. each of
7 trials runs every configuration once, in alternating order; medians are
shown. every payload is decoded by the codec that made it and compared to the
message. reproduce with `zig build bench -- --frames <path> --trials 7`.

machine: Apple M5 Pro, macOS 26.5.1, Zig 0.17.0. measured 2026-11-10.

## relay frames

3,160 `com.atproto.sync.subscribeRepos` frames (16.9 MB, mean 5.4 KB):
atproto-bench's `fixtures/firehose-frames.bin`, sha256 prefix
`40986f3c9dadb7f9`. this is what a relay sends a subscriber.

| codec | level | takeover | payload / raw | encode MB/s | decode MB/s | heap per connection |
|---|---:|---|---:|---:|---:|---:|
| pmdeflate | 1 | on | 0.6707 | 87.6 | 241.2 | 375 KiB |
| zlib | 1 | on | 0.6729 | 80.2 | 373.7 | ~422 KiB |
| pmdeflate | 6 | on | 0.6530 | 66.2 | 250.5 | 375 KiB |
| zlib | 6 | on | 0.6511 | 55.2 | 398.5 | ~422 KiB |
| pmdeflate | 6 | off | 0.7055 | 104.1 | 232.0 | 375 KiB |
| zlib | 6 | off | 0.7050 | 83.0 | 379.1 | ~422 KiB |

## test corpus

`test/corpus.zig`: 376 messages, 1.25 MB, heavy in incompressible noise and
long runs.

| codec | level | takeover | payload / raw | encode MB/s | decode MB/s | heap per connection |
|---|---:|---|---:|---:|---:|---:|
| pmdeflate | 1 | on | 0.5251 | 124.1 | 309.6 | 369 KiB |
| zlib | 1 | on | 0.5225 | 138.5 | 1765.3 | ~422 KiB |
| pmdeflate | 6 | on | 0.5192 | 118.8 | 327.3 | 369 KiB |
| zlib | 6 | on | 0.5163 | 118.3 | 1236.5 | ~422 KiB |
| pmdeflate | 6 | off | 0.5575 | 115.3 | 318.3 | 369 KiB |
| zlib | 6 | off | 0.5564 | 125.7 | 940.8 | ~422 KiB |

## reading it

- compression ratio is within 0.6% of zlib at every configuration.
- on relay frames pmdeflate encodes 9–25% faster than zlib; on the noisy test
  corpus it is up to 11% slower at level 1 and level with zlib at 6.
- decoding is slower: 0.61–0.65x zlib on relay frames and 0.18–0.34x on the test
  corpus, whose stored blocks and long runs zlib copies very quickly. the
  decoder is std's `flate.Decompress`, and every message is decoded into its
  buffer and then copied to the caller's writer.
- heap is pmdeflate's measured allocation for one deflater and one inflater.
  zlib allocates through malloc, so its figure is the documented state size
  (deflate 384 KiB at windowBits 15, memLevel 8; inflate 32 KiB) plus this
  harness's buffer, an estimate rather than a measurement.
