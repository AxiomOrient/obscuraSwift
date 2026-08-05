# Completion Report

Status: COMPLETE

## 1. 판정

이 작업본의 source-level 완료 게이트는 2026-08-05 macOS에서 모두 통과했다. 정확한 vendored Obscura source를 Cargo로 빌드했고, Swift CLI가 그 binary를 실제로 launch하여 discovery, browser WebSocket, target/session 초기화와 page operation을 수행했다.

이제 canonical local Git history와 clean working tree가 확보되었으며, 이 report의 `Status: COMPLETE`는 package gate를 실행할 수 있는 source revision에 기록되었다. release archive gate는 이 revision에서 `Scripts/package-verified.sh`가 생성·검증한다.

## 2. 이번 검증 환경과 증거

- Host: Darwin 25.5.0, arm64
- Swift: 6.3.3
- Cargo: 1.97.0
- Vendored source archive SHA-256: `bd474a7d743d6229ac369b435e5ca862e20ea1836266db64bb21047e10b02268`
- Vendored manifest: 138 files, exact SHA-256 match, symlink 없음

| Gate | Result |
|---|---|
| `Scripts/verify-vendor.sh` | PASS — 시작·종료 시 vendor hash와 138개 manifest 일치 |
| `Scripts/verify-process-boundary.sh` | PASS — macOS에서 Linux 전용 `PR_SET_PDEATHSIG` 검사는 명시적으로 skip |
| `Scripts/build-vendored-obscura.sh` | PASS — exact Cargo workspace, lockfile, release binary |
| `Scripts/verify-swift.sh` debug | PASS — strict format, warnings-as-errors, 87/87 tests, CLI fixture doctor |
| `Scripts/verify-swift.sh` release | PASS — strict format, warnings-as-errors, 87/87 tests, CLI fixture doctor |
| `Scripts/verify-runtime.sh` | PASS — actual vendored engine launch, data URL/title/selector/cleanup |
| `Scripts/verify-all.sh` | PASS — 위 gate를 순서대로 모두 실행 |
| `Scripts/package-verified.sh` | READY — COMPLETE report와 clean canonical Git revision을 기준으로 archive 생성·clean extraction 검증 |

## 3. 이번에 해소한 실제 계약 불일치

- macOS `wait` status macro가 addressable status 값을 요구하는 C 컴파일 결함을 수정했다.
- Swift socket/timeval code와 test socket code를 Darwin/Linux 양쪽에서 올바르게 형식화했다.
- test fixture의 asyncio event를 실행 loop 안에서 만들도록 고쳐 Python 3.9 loop ownership 오류를 제거했다.
- vendored control-plane이 `Accept: application/json` 안의 `/json`을 path로 오인하므로, 응답 content type 검증은 유지하고 request header만 `Accept: */*`로 바꿨다.
- 실제 Obscura는 dedicated page endpoint의 무세션 명령이 아니라 browser endpoint의 `Target.createTarget → Target.attachToTarget` 절차를 요구한다. Swift adapter는 그 단일 session을 확정한 뒤 Page/Runtime/Network 요청과 response/event session을 엄격히 상관시킨다.
- vendor 전용 CDP handshake를 `BrowserSession` lifecycle actor에서 stateless `VendoredObscuraSessionBootstrap` adapter로 분리하고, 정확한 request/session sequence를 단위 테스트로 고정했다.

`Vendor/Obscura` source는 수정하지 않았다. Swift fixture와 protocol test는 실제 browser-level CDP handshake를 재현하며, matching session response만 수용하는 회귀 검사를 포함한다.

## 4. Archive gate

이 report가 포함된 clean canonical Git revision에서 다음을 실행한다.

```bash
./Scripts/package-verified.sh
```

이 script는 full verification 재실행, Git commit 기반 ZIP 생성, 임시 clean extraction에서의 재검증, SHA-256 생성을 수행한다. 성공한 archive와 checksum은 이 완료 판정의 release provenance 증거다.

## 5. 남은 경계

- Linux 전용 parent-death containment은 macOS 결과로 대체하지 않는다.
- macOS codesign/notarization과 Apple UI integration은 현재 Swift package verification 범위 밖이다.
- local Git provenance는 이 revision에 기록되어 있다. archive reproducibility는 이 revision에서 `Scripts/package-verified.sh`가 성공할 때 증명된다.
