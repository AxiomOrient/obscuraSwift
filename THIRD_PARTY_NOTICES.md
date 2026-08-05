# Third-party notices

This source publication has no declared external Swift package dependencies.
[`Package.swift`](Package.swift) declares only targets in this repository.

## Vendored Obscura engine

The package includes an immutable external Rust source snapshot under
[`Vendor/Obscura`](Vendor/Obscura). Its recorded upstream is
<https://github.com/h4ckf0r0day/obscura>. The immutable provenance record is
[`Vendor/OBSCURA_SOURCE.json`](Vendor/OBSCURA_SOURCE.json), including the
source-archive hash and the policy that the snapshot is used as-is.

The complete Apache-2.0 license text for the vendored engine is kept at
[`Vendor/Obscura/LICENSE`](Vendor/Obscura/LICENSE). This notice identifies the
license file and does not add a separate top-level license for ObscuraSwift.

### Direct Rust dependencies

Obscura is an eight-package Cargo workspace. The inventory below names every
external registry crate declared directly by a workspace member. It was checked
with `cargo metadata --locked --offline --format-version 1` from
`Vendor/Obscura`, which reported 356 package records, 8 workspace members, and
87 external direct-dependency declarations (80 resolved direct edges and 38
unique external packages with the default feature set). Each version and SPDX
expression below comes from resolved package metadata; the two optional
`stealth` entries use their exact `Cargo.lock` pins and package metadata because
they are not activated by the default feature set. `build`, `dev`, `optional`,
and target/feature qualifiers describe the declaration context.

Workspace path dependencies (`obscura-*`) are internal to the vendored
workspace and are not repeated as external attributions.

#### `obscura-dom`

- `cssparser` 0.34.0 — `MPL-2.0`
- `html5ever` 0.29.1 — `MIT OR Apache-2.0`
- `markup5ever` 0.14.1 — `MIT OR Apache-2.0`
- `precomputed-hash` 0.1.1 — `MIT`
- `selectors` 0.26.0 — `MPL-2.0`
- `servo_arc` 0.4.3 — `MIT OR Apache-2.0`
- `thiserror` 2.0.18 — `MIT OR Apache-2.0`
- `tracing` 0.1.44 — `MIT`

#### `obscura-net`

- `async-trait` 0.1.89 — `MIT OR Apache-2.0`
- `encoding_rs` 0.8.35 — `(Apache-2.0 OR MIT) AND BSD-3-Clause`
- `reqwest` 0.12.28 — `MIT OR Apache-2.0` (`default-features = false`; `gzip`, `brotli`, `deflate`, `rustls-tls`, `socks`)
- `serde` 1.0.228 — `MIT OR Apache-2.0` (`derive`)
- `serde_json` 1.0.150 — `MIT OR Apache-2.0`
- `tempfile` 3.27.0 — `MIT OR Apache-2.0`
- `thiserror` 2.0.18 — `MIT OR Apache-2.0`
- `tokio` 1.52.3 — `MIT` (`full`)
- `tracing` 0.1.44 — `MIT`
- `url` 2.5.8 — `MIT OR Apache-2.0`
- `wreq-util` 3.0.0-rc.12 — `Apache-2.0` (optional; enabled by the `stealth` feature)
- `wreq` 6.0.0-rc.29 — `Apache-2.0` (optional; enabled by `stealth`; `prefix-symbols`, `socks` on Linux/Android and `socks` on other targets)

The two optional `stealth` crates are pinned in `Cargo.lock` but are not in
the default-feature metadata resolution; they are listed here rather than
silently omitted.

#### `obscura-browser`

- `anyhow` 1.0.102 — `MIT OR Apache-2.0`
- `base64` 0.22.1 — `MIT OR Apache-2.0`
- `futures` 0.3.32 — `MIT OR Apache-2.0`
- `serde_json` 1.0.150 — `MIT OR Apache-2.0`
- `thiserror` 2.0.18 — `MIT OR Apache-2.0`
- `tokio` 1.52.3 — `MIT` (`full`)
- `tracing` 0.1.44 — `MIT`
- `url` 2.5.8 — `MIT OR Apache-2.0`

#### `obscura-js`

- `aes` 0.8.4 — `MIT OR Apache-2.0`
- `aes-gcm` 0.10.3 — `Apache-2.0 OR MIT`
- `anyhow` 1.0.102 — `MIT OR Apache-2.0`
- `base64` 0.22.1 — `MIT OR Apache-2.0`
- `cbc` 0.1.2 — `MIT OR Apache-2.0` (`alloc`)
- `ctr` 0.9.2 — `MIT OR Apache-2.0`
- `deno_core` 0.350.0 — `MIT` (runtime and build dependency)
- `deno_error` 0.6.1 — `MIT`
- `getrandom` 0.2.17 — `MIT OR Apache-2.0`
- `hkdf` 0.12.4 — `MIT OR Apache-2.0`
- `hmac` 0.12.1 — `MIT OR Apache-2.0`
- `html5ever` 0.29.1 — `MIT OR Apache-2.0`
- `pbkdf2` 0.12.2 — `MIT OR Apache-2.0` (`default-features = false`; `hmac`)
- `reqwest` 0.12.28 — `MIT OR Apache-2.0` (`default-features = false`; `gzip`, `brotli`, `deflate`, `rustls-tls`, `socks`)
- `serde` 1.0.228 — `MIT OR Apache-2.0` (`derive`)
- `serde_json` 1.0.150 — `MIT OR Apache-2.0`
- `sha1` 0.10.6 — `MIT OR Apache-2.0`
- `sha2` 0.10.9 — `MIT OR Apache-2.0`
- `thiserror` 2.0.18 — `MIT OR Apache-2.0`
- `tokio` 1.52.3 — `MIT` (`full`)
- `tracing` 0.1.44 — `MIT`
- `url` 2.5.8 — `MIT OR Apache-2.0`

#### `obscura-cdp`

- `anyhow` 1.0.102 — `MIT OR Apache-2.0`
- `base64` 0.22.1 — `MIT OR Apache-2.0`
- `futures-util` 0.3.32 — `MIT OR Apache-2.0` (runtime and dev dependency)
- `libc` 0.2.186 — `MIT OR Apache-2.0` (target `cfg(target_env = "gnu")`)
- `serde` 1.0.228 — `MIT OR Apache-2.0` (`derive`)
- `serde_json` 1.0.150 — `MIT OR Apache-2.0`
- `thiserror` 2.0.18 — `MIT OR Apache-2.0`
- `tokio` 1.52.3 — `MIT` (`full`)
- `tokio-tungstenite` 0.26.2 — `MIT` (runtime and dev dependency)
- `tracing` 0.1.44 — `MIT`
- `url` 2.5.8 — `MIT OR Apache-2.0`
- `uuid` 1.23.3 — `Apache-2.0 OR MIT` (`v4`)

#### `obscura-mcp`

- `anyhow` 1.0.102 — `MIT OR Apache-2.0`
- `serde` 1.0.228 — `MIT OR Apache-2.0` (`derive`)
- `serde_json` 1.0.150 — `MIT OR Apache-2.0`
- `tokio` 1.52.3 — `MIT` (`full`)
- `tracing` 0.1.44 — `MIT`
- `url` 2.5.8 — `MIT OR Apache-2.0`

#### `obscura-cli`

- `anyhow` 1.0.102 — `MIT OR Apache-2.0`
- `clap` 4.6.1 — `MIT OR Apache-2.0` (`derive`)
- `serde` 1.0.228 — `MIT OR Apache-2.0` (`derive`)
- `serde_json` 1.0.150 — `MIT OR Apache-2.0`
- `tokio` 1.52.3 — `MIT` (`full`)
- `tracing` 0.1.44 — `MIT`
- `tracing-subscriber` 0.3.23 — `MIT` (`env-filter`)
- `url` 2.5.8 — `MIT OR Apache-2.0`

#### `obscura`

- `anyhow` 1.0.102 — `MIT OR Apache-2.0`
- `serde` 1.0.228 — `MIT OR Apache-2.0` (`derive`)
- `serde_json` 1.0.150 — `MIT OR Apache-2.0`
- `thiserror` 1.0.69 — `MIT OR Apache-2.0`
- `tokio` 1.52.3 — `MIT` (optional; enabled by the default `api` feature with `rt`; dev dependency also uses `rt-multi-thread`, `macros`, `sync`, `time`)
- `url` 2.5.8 — `MIT OR Apache-2.0`

The vendored engine's [`Cargo.lock`](Vendor/Obscura/Cargo.lock) contains the
exact full runtime, optional, transitive, and build-time graph (384 package
entries). Those packages are dependencies of the vendored engine, not Swift
Package Manager dependencies. This notice lists direct declarations only; the
lockfile and each package's own metadata and license files remain the source
of attribution for transitive components.

## Source-only publication limits

The source publication keeps the vendored source, provenance, hash manifest,
and license together. It does not publish compiled `Vendor/Obscura/target/` or
`.build/` output, generated archives, or a system Chrome/Chromium installation.
Build and runtime evidence therefore depends on the operator's local Rust,
Swift, Python, and browser environment; this notice does not assert that those
environment-specific artifacts are included here.
