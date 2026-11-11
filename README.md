# pmdeflate

permessage-deflate ([RFC 7692](https://www.rfc-editor.org/rfc/rfc7692)) for WebSocket in pure Zig 0.17: compression on `std.compress.flate`, decompression with its own table-driven inflater. no C, no libc: it builds for Linux, macOS, Windows, FreeBSD, wasm32-freestanding and wasm32-wasi.

```zig
const pmdeflate = @import("pmdeflate");

const deflater = try pmdeflate.Deflater.create(gpa, .{ .context_takeover = true });
defer deflater.destroy();
const payload = try deflater.compress(message); // valid until the next compress

const inflater = try pmdeflate.Inflater.create(gpa, .{ .context_takeover = true });
defer inflater.destroy();
const len = try inflater.decompress(payload, &out_writer, max_message_len);
```

`compress` returns the frame payload: DEFLATE data ending in a sync flush, with the trailing `00 00 ff ff` removed. `decompress` reverses it and refuses to write more than `max_len` bytes. after an error an `Inflater` refuses every message until `reset`, since its window is unknown.

turn `context_takeover` off for a direction when `client_no_context_takeover` or `server_no_context_takeover` was agreed for it. an `Inflater` accepts any `*_max_window_bits`. a `Deflater` may reference 32 KiB back, so it can only honor `max_window_bits=15`; decline offers that need less.

## install

```sh
zig fetch --save=pmdeflate https://tangled.org/zzstoatzz.io/pmdeflate/archive/v0.1.0.tar.gz
```

```zig
exe.root_module.addImport("pmdeflate", b.dependency("pmdeflate", .{}).module("pmdeflate"));
```

## develop

```sh
zig build test          # RFC 7692 section 7.2.3 examples and unit tests
zig build targets       # build for every portable target, wasm included
zig build differential  # round-trip against zlib 1.3.2, both directions
zig build pbt           # hegel campaigns; HEGEL_TEST_CASES sets the budget
zig build bench -- --frames path/to/frames.bin
```

zlib and hegel are lazy dependencies of the test and bench steps, fetched only when pmdeflate is the root build, so consumers never download them. everything runs offline once they are fetched. [docs/conformance.md](docs/conformance.md) covers what is tested and how the campaign was calibrated; [docs/bench.md](docs/bench.md) has measurements against zlib.

## license

MIT

[changelog](CHANGELOG.md)
