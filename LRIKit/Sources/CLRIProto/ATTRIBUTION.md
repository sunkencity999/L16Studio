# Attribution

The `.proto` files in this directory are copied from
[gennyble/lri-rs](https://github.com/gennyble/lri-rs) (`lri-proto/proto/`),
which in turn credits [dllu/lri-rs](https://github.com/dllu/lri-rs) (Daniel
Lawrence Lu) as the origin of these protobuf definitions, reverse-engineered
from Light Co.'s L16 camera and Lumen desktop software.

- `lri-proto` crate: MIT License, Copyright (c) 2021 Daniel Lawrence Lu
- `lri-rs`/`prism` crates (format documentation, block parsing approach):
  ISC License, Copyright 2023 gennyble <gen@nyble.dev>

Both licenses are permissive and this reuse complies with their terms
(this notice satisfies the attribution requirement of both).

The Swift parsing code in the parent `LRIKit` package is an original
implementation written for this project, informed by the format
documentation and Rust reference implementation above, not a direct
translation of their source.
