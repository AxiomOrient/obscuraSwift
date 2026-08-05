# Verification Contract

완료 판정은 동일한 source revision에서 모든 source-level gate와 archive gate가 필요한 증거를 남겼을 때만 가능하다. 한 개의 unit test 또는 fixture doctor 성공은 completion을 뜻하지 않는다.

## Source-level gate

```bash
./Scripts/verify-all.sh
```

이 script는 다음 순서를 fail-fast로 실행한다.

| 단계 | 명령 | 확인 내용 |
|---|---|---|
| vendor | `./Scripts/verify-vendor.sh` | exact file set, SHA-256 manifest, symlink 부재, immutable source hash |
| process | `./Scripts/verify-process-boundary.sh` | Linux에서는 C boundary ASan/UBSan과 parent-death containment, 다른 OS에서는 Linux 전용 검사 skip |
| engine | `./Scripts/build-vendored-obscura.sh` | locked Cargo release build와 expected executable |
| Swift | `./Scripts/verify-swift.sh` | strict format, warnings-as-errors, debug/release XCTest, fixture CLI doctor, fixture child cleanup |
| runtime | `./Scripts/verify-runtime.sh` | actual vendored engine을 launch하는 CLI doctor |
| vendor recheck | `./Scripts/verify-vendor.sh` | build가 immutable source를 바꾸지 않았는지 재확인 |

필요할 때 개별 script를 실행할 수 있지만, completion 근거에는 전체 command의 성공이 필요하다. `verify-swift.sh`는 `swift-format`이 있으면 이를 사용하고, 없으면 Swift toolchain의 `swift format`으로 strict lint를 실행한다.

## Archive gate

```bash
./Scripts/package-verified.sh
```

이 gate는 다음을 강제한다.

- `COMPLETION_REPORT.md`에 정확히 `Status: COMPLETE`가 있음
- Git working tree가 clean함
- source-level verification 재실행
- Git commit 기반 ZIP 생성
- 임시 clean extraction에서 source-level verification 재실행
- archive SHA-256 생성

Git metadata가 없는 전달본에서는 canonical revision, clean tree, `git archive`를 증명할 수 없으므로 이 gate를 실행하지 않는다. 현재 blocker와 source-level evidence는 [completion report](../COMPLETION_REPORT.md)를 따른다.

## Platform evidence

Linux의 `PR_SET_PDEATHSIG` containment은 Linux host에서만 검증한다. macOS에서 이 단계가 skip되는 것은 성공으로 가장하지 않으며, 반대로 Linux 결과는 macOS signing/notarization 또는 URLSession WebSocket 동작을 증명하지 않는다.

이 package에 Apple UI target은 없으므로 SwiftUI/Observation/TCA integration은 verification 대상이 아니다. 실제 public surface와 runtime boundary는 [architecture](ARCHITECTURE.md)를 따른다.
