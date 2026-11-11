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
| payloads, corrupted or intact | a flipped bit, truncation, appended or spliced noise, a replaced payload, or none, with limits drawn around the message length: pmdeflate makes zlib's exact accept/refuse decision and, when both accept, produces the same message. nothing is written past the limit, and a refusal poisons the inflater until reset. |
| generated blocks | blocks written from RFC 1951 rather than by an encoder: dynamic Huffman blocks that are valid or have one table defect (incomplete, oversubscribed, no end-of-block, too many length or distance symbols) and stored blocks with a good or broken NLEN, coded with their own tables. pmdeflate makes zlib's decision and a valid block decodes to its message. |

the zlib oracle is adjusted in two places so that "zlib accepts" means what
a WebSocket receiver means. at a BFINAL block zlib ends its stream; the
oracle restarts with `inflateReset` and the last 32 KiB of output as a
dictionary, as RFC 7692 7.2.3.4 continues with the same window. and zlib
treats input that stops mid-block as waiting for more, so the oracle accepts
a payload only when all of it is consumed at a block boundary or a stream
ended there; otherwise an empty or truncated payload looked accepted.

messages are drawn by shape and size bucket so the cases that matter are
common: messages longer than the window, large messages that fill the
inflater's history past where it compacts, references exactly one window
back, repeats, and message data after a BFINAL block.

### calibration

`zig build mutants` plants each entry of `pbt/mutants.zon` and runs the
campaign under ten seeds at 300 cases. on 2026-11-11 each mutant ran on its
own Fly `performance-1x` machine against `7b92c64`, and the unmutated baseline
passed 10 of 10 on every machine. the fast-loop mutants were rerun against
`c3bc56f`'s properties:

| mutant | caught |
|---|---|
| finding: a refused message writes one byte past `max_len` | 9/10 |
| deflater keeps its window with takeover off | 10/10 |
| inflater keeps one byte less than the window | 10/10 |
| inflater is not poisoned after an error | 10/10 |
| inflater stops after the first BFINAL block | 10/10 |
| inflater writes a literal past the limit | 10/10 |
| incomplete code tables are accepted | 10/10 |
| a stored block's NLEN is not checked | 10/10 |
| 287 or 288 length symbols, or 31 or 32 distance symbols, are accepted | 10/10 |
| input left over at the end of a payload is accepted | 10/10 |
| fast path: unrolled literals ignore the limit | 6/10 |
| fast path: a literal ignores the limit | 7/10 |
| fast path: a match ignores the limit | 10/10 |
| fast path: a short-distance pattern steps a whole word | 10/10 |
| fast path: 16-byte copies overlap their source | 10/10 |
| fast path: a distance past the history is accepted | crashes 10/10 |

a fast-loop limit check that goes missing is invisible on most payloads: the
next symbol trips the careful path's check, so the message is refused
anyway. it shows only when the message's last symbol is decoded in the fast
loop, which the end of a payload never is, so the corrupted-payload property
sometimes pads a payload with empty stored blocks, as RFC 7692 allows. the
distance mutant reads before the output buffer and crashes the test run on
every seed: caught, but not by a property.

what the earlier runs exposed, in order:

- caught 3 of 6 against std's decoder: an over-limit mutant returned a
  truncated message and no property compared it with zlib's full length; a
  mutant crashed on an integer underflow instead of failing a property; a
  window mutant used a condition std's rebase never reaches.
- caught 6 of 10 against the new inflater: the header mutants survived
  because random corruption rarely forms a valid dynamic header with one
  defect, and the generated-block property did not exist yet. its first
  version coded data with the valid table, so a defective table also broke
  the data and both decoders refused for the wrong reason.
- removed as equivalent: dropping the end-of-block check. a block without an
  end-of-block code cannot end, so a whole payload is refused either way.

### findings

- the output limit allowed one byte past `max_len` before refusing. found by
  the corrupted-payload property on its first run; fixed, with a regression
  in `src/rfc7692_test.zig`.

### Autobahn

websocket.zig runs Autobahn TestSuite's 517 cases against echo servers with
and without context takeover (`support/autobahn` on its
`build/pmdeflate-codec` branch). with pmdeflate's std-based decoder,
pmdeflate and zlib produced the same behavior on all 1,551 case results,
with no failures; the declined cases are offers of `max_window_bits`
below 15.

### gaps

- the deflater cannot limit match distance, so `max_window_bits` below 15 is
  unsupported rather than tested.
- the generated blocks cover dynamic and stored headers; fixed-Huffman
  blocks are reached through the encoders and corruption only.
