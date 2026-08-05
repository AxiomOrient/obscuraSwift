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

The vendored engine's [`Cargo.lock`](Vendor/Obscura/Cargo.lock) resolves its
Rust runtime, transitive, and build-time dependencies. Those packages are
dependencies of the vendored engine, not Swift Package Manager dependencies;
this notice does not duplicate the lockfile's complete package graph. Their
individual package metadata and license files remain the source of attribution
for that graph.

## Source-only publication limits

The source publication keeps the vendored source, provenance, hash manifest,
and license together. It does not publish compiled `Vendor/Obscura/target/` or
`.build/` output, generated archives, or a system Chrome/Chromium installation.
Build and runtime evidence therefore depends on the operator's local Rust,
Swift, Python, and browser environment; this notice does not assert that those
environment-specific artifacts are included here.
