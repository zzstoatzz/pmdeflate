# conformance

three independent checks, then a calibration that shows they catch real
mistakes.

## RFC 7692 examples

`src/rfc7692_test.zig` decodes every worked example in section 7.2.3 byte for
byte: one compressed block, the shared-window second `Hello` (and its refusal
without the window), a stored block, a BFINAL block followed by a stored
header, two blocks in one message, and the single-byte empty fragment. it
also pins the output limit: a refused message writes nothing past `max_len`.

## differential against zlib

`test/differential.zig` sends a deterministic corpus (`test/corpus.zig`:
jetstream-shaped JSON, binary frames, empty and one-byte messages, runs and
noise at 32 KiB and 64 KiB boundaries, and repeats) through both pairings, at
levels 1, 6 and 9, with and without context takeover:

- pmdeflate encodes, zlib 1.3.2 decodes
- zlib encodes, pmdeflate decodes

## hegel properties

`pbt/properties.zig` treats a case as one direction of a connection: a level,
a takeover mode, then a generated history.

| property | oracle |
|---|---|
| pmdeflate encodes | pmdeflate and zlib both decode each payload to the message. resets clear both ends. payloads are sometimes rewritten as RFC 7692 7.2.3.4 allows: ending in a BFINAL block, or splitting the message across a BFINAL block. |
| zlib encodes | pmdeflate decodes each payload to the message |
| corrupted payloads | a flipped bit, truncation, appended or spliced noise, or a replaced payload is refused or decoded within the limit, never a crash. when both decoders accept it they agree. a refusal poisons the inflater until reset. |

messages are drawn by shape and size bucket so the cases that matter are
common. in a 1,000-case run of the encode property (`HEGEL_SEED=7`), 35% of
cases hold a message longer than the window, 49% reference bytes exactly one
window back, 59% carry message data after a BFINAL block, and 39% reset
after a message; the corruption property refused 85% of its payloads.

### calibration

each mutant below was planted in a disposable copy and run for 300 cases on
seeds 1, 2 and 3 (`HEGEL_SEED`).

| mutant | caught |
|---|---|
| deflater keeps its window with takeover off | 3/3 |
| inflater keeps one byte less than the window | 0/3 before the window-edge shape, 3/3 after |
| inflater is not poisoned after an error | 3/3 |
| inflater stops after the first BFINAL block | 0/3 before data followed BFINAL, 3/3 after |
| inflater writes one byte past the limit | 3/3, by an integer-overflow panic rather than a property |

### findings

- the output limit allowed one byte past `max_len` before refusing. found by
  the corrupted-payload property on its first run; fixed, with a regression
  in `src/rfc7692_test.zig`.

### gaps

- no Autobahn run yet: framing, fragmentation and negotiation belong to the
  WebSocket library that uses this codec.
- zlib stops at a BFINAL block, so payloads that use one are checked by
  pmdeflate's own decoding and the RFC examples, not by zlib.
- the deflater cannot limit match distance, so `max_window_bits` below 15 is
  unsupported rather than tested.
