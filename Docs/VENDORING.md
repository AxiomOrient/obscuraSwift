# Vendored Obscura Policy

`Vendor/Obscura`는 first-party source가 아닌 immutable external Rust snapshot이다. ObscuraSwift는 그 source를 patch하거나 runtime에 다른 engine을 다운로드하지 않는다.

## Authority와 build output

다음 파일이 snapshot identity를 정의한다.

- [`Vendor/OBSCURA_SOURCE.json`](../Vendor/OBSCURA_SOURCE.json)
- [`Vendor/OBSCURA_FILES.sha256`](../Vendor/OBSCURA_FILES.sha256)

build output은 `Vendor/Obscura/target/`에만 둔다. vendor verifier는 이 생성물을 source set와 archive hash에서 제외하고, 나머지 file set·hash·symlink 상태를 fail-closed로 검사한다.

## 허용하지 않는 변경

- vendor source에 product patch 적용
- engine build 실패 후 이전 binary를 조용히 사용
- runtime의 자동 download 또는 version fallback
- source/binary를 가리키는 symbolic link 주입
- `Cargo.lock` 무시
- `RUSTC_WRAPPER`, `RUSTFLAGS`, V8 archive override 같은 ambient build substitution

## Build와 runtime 확인

```bash
./Scripts/build-vendored-obscura.sh
./Scripts/verify-runtime.sh
```

build script는 verifier를 전후로 실행하고 exact manifest, locked Cargo resolution, release profile, 지정 target directory를 사용한다. runtime verifier는 `Vendor/Obscura/target/release/obscura`를 실제로 launch하는 Swift CLI doctor를 실행한다.

## Snapshot 갱신 절차

1. 새 upstream snapshot을 repository 밖의 staging directory에서 provenance와 license까지 확인한다.
2. `Vendor/Obscura` 전체를 새 snapshot으로 교체한다. 부분 patch는 적용하지 않는다.
3. source archive hash와 file manifest를 새 snapshot에 맞춰 갱신한다.
4. `./Scripts/verify-vendor.sh`, `./Scripts/build-vendored-obscura.sh`, `./Scripts/verify-all.sh`를 실행한다.
5. Swift adapter가 의존하는 discovery, browser session, cookie, navigation compatibility 변화와 남은 위험을 [completion report](../COMPLETION_REPORT.md)에 기록한다.

vendored project 자체의 사용법과 upstream API는 [`Vendor/Obscura/README.md`](../Vendor/Obscura/README.md)를 따른다. 그 문서는 ObscuraSwift의 public Swift API를 설명하지 않는다.
