# ObscuraSwift

ObscuraSwift는 기본적으로 immutable vendored Obscura Rust engine을, 선택적으로 설치된 Google Chrome/Chromium을 별도 process로 실행하고 그 수명과 CDP 경계를 Swift Concurrency API로 감싸는 macOS 13+ Swift package다. 브라우저 엔진을 Swift로 재구현하거나 vendored source를 patch하지 않으며, `ObscuraKit`은 process containment, 단일 page session, typed value/error boundary와 명시적 recovery만 소유한다.

## 읽는 순서와 기준 파일

| 목적 | 기준 파일 | 설명 |
|---|---|---|
| package product·platform·target | [Package.swift](Package.swift) | `ObscuraKit` library와 `obscura-swift` executable의 선언 |
| 사용법과 저장소 탐색 | 이 문서 | 지원 범위, CLI, public API 진입점 |
| 설계 경계 | [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md) | session, process, CDP protocol의 책임과 실패 처리 |
| 기능 추적 | [Docs/CORE_CONTRACT_MATRIX.md](Docs/CORE_CONTRACT_MATRIX.md) | 핵심 기능의 state/event/effect/failure/test 연결 |
| vendor policy | [Docs/VENDORING.md](Docs/VENDORING.md) | immutable snapshot, build, update 규칙 |
| 검증과 archive | [Docs/VERIFICATION.md](Docs/VERIFICATION.md) | 실행 가능한 verification·packaging gate |
| 현재 완료 증거 | [COMPLETION_REPORT.md](COMPLETION_REPORT.md) | 이 작업본의 검증 결과와 archive blocker |

`Package.swift`, source, tests, scripts가 문서보다 우선한다. `.build/`, `.cache/`, `Vendor/Obscura/target/`은 생성물이므로 source authority가 아니다.

## Source publication boundary

`Vendor/Obscura` is an immutable external snapshot, not first-party Swift API.
Its source, `LICENSE`, provenance manifest, and hash manifest must remain together;
the vendored engine must not be patched, downloaded at runtime, or replaced by a
silent fallback. `Vendor/Obscura/target/`, `.build/`, `.cache/`, reports, ZIP files,
and local credentials are generated or environment-specific. Source publication is
separate from the Git archive/package gate and from macOS/Linux runtime evidence.

Vendored Obscura provenance and license attribution are recorded in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## 제공 범위

`ObscuraKit`은 한 session에서 한 개의 새 page target을 만들고 제어한다.

- URL navigation과 `NavigationWait`
- JSON으로 표현 가능한 JavaScript 평가, title/current URL/HTML 조회
- CSS selector 기반 text·attribute 조회, DOM click, value 설정
- cookie 조회·설정, cookie-only checkpoint, 새 process를 이용한 명시적 recovery
- bounded operation queue, timeout/cancellation, process exit와 protocol failure 격리

다음은 public contract가 아니다.

- screenshot, PDF, layout, bounding box, visual actionability
- Playwright/Puppeteer API 또는 auto-wait 호환성
- raw CDP, remote JavaScript object, multi-tab, shared browser context
- 실패한 요청의 자동 retry, 다른 engine으로의 fallback, session 내부 자동 복구

## 요구 사항

- Swift 6.2 이상; package manifest는 macOS 13 이상을 선언한다.
- vendored engine build를 위한 Rust toolchain (`cargo`, `rustc`).
- integration fixture와 runtime assertion을 위한 Python 3.

POSIX process layer에는 Darwin과 Linux code path가 있다. 다만 Linux parent-death containment 검사는 Linux에서만 실행되며, macOS 결과로 대체되지 않는다.

## 빠른 시작

vendored source를 먼저 검증·빌드한 뒤 CLI doctor를 실행한다.

```bash
./Scripts/build-vendored-obscura.sh
swift run -c release obscura-swift doctor --repository-root "$PWD"
swift run -c release obscura-swift run https://example.com --repository-root "$PWD"
```

기본 위치가 아닌 engine binary를 사용할 때만 `--engine /absolute/path/to/obscura`를 사용한다. `--engine`과 `--repository-root`는 함께 쓸 수 없다.

## Engine mode

기본은 검증된 vendored Obscura다. 별도 Obscura-compatible binary에는 --engine PATH,
실제 Google Chrome/Chromium에는 --chrome PATH를 사용한다.

~~~bash
swift run -c release obscura-swift doctor \
  --chrome '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'

swift run -c release obscura-swift run https://example.com \
  --chrome '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
~~~

Swift에서는 같은 선택을 명시적으로 표현한다.

~~~swift
let configuration = try LaunchConfiguration.chrome(
  executable: URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
)
let session = try await BrowserSession.launch(configuration)
~~~

Chrome mode는 독립 temporary profile, --headless=new, loopback-only CDP를 사용한다.
Chrome 자체의 네트워크 정책이 적용되므로 Obscura 전용 stealth 옵션은 Chrome mode에서 거부된다.
allowPrivateNetwork도 Chrome mode의 네트워크 정책을 제어하지 않는다.

## Swift 사용

```swift
import Foundation
import ObscuraKit

func inspect(repositoryRoot: URL) async throws {
  let configuration = try LaunchConfiguration(
    executable: .vendored(repositoryRoot: repositoryRoot)
  )
  let session = try await BrowserSession.launch(configuration)

  do {
    let result = try await session.navigate(
      to: URL(string: "https://example.com")!,
      waitUntil: .load
    )
    let title = try await session.title()
    let heading = try await session.locator(try CSSSelector("h1")).textContent()
    print(result.url, title, heading ?? "")
    await session.close()
  } catch {
    await session.close()
    throw error
  }
}
```

정상 수명은 소유자가 `await session.close()`로 끝낸다. `deinit`의 강제 종료는 abandoned session의 containment일 뿐, 정상 종료 계약이 아니다.

terminal failure 뒤에는 기존 session을 재사용하지 않는다. checkpoint에는 compatibility와 cookie만 보존되며 DOM, V8 state, listener, timer, navigation은 복원되지 않는다.

```swift
let checkpoint = try await session.checkpoint()
let replacement = try await session.recover(from: checkpoint)
```

## 검증

모든 source-level gate는 한 번에 실행한다.

```bash
./Scripts/verify-all.sh
```

| 명령 | 검증 대상 |
|---|---|
| `./Scripts/verify-vendor.sh` | immutable vendor file set와 hash |
| `./Scripts/verify-process-boundary.sh` | Linux에서 C boundary ASan/UBSan과 parent-death path; 다른 OS에서는 Linux 전용 검사 skip |
| `./Scripts/build-vendored-obscura.sh` | exact locked Cargo release build |
| `./Scripts/verify-swift.sh` | strict format, warnings-as-errors, debug/release XCTest, fixture CLI doctor |
| `./Scripts/verify-runtime.sh` | 실제 vendored binary를 사용한 CLI doctor |

release ZIP은 별도 gate다. canonical Git checkout에서 clean working tree와 `COMPLETION_REPORT.md`의 `Status: COMPLETE`를 확보한 경우에만 `./Scripts/package-verified.sh`가 Git archive와 clean extraction 재검증을 수행한다. 현재 상태는 [completion report](COMPLETION_REPORT.md)를 따른다.

## 저장소 구조

| 영역 | 역할 | public surface |
|---|---|---|
| [Sources/ObscuraKit](Sources/ObscuraKit) | domain value, reducer, runtime actor, adapter | `ObscuraKit` library |
| [Sources/CObscuraProcess](Sources/CObscuraProcess) | POSIX spawn/wait boundary | internal C target |
| [Sources/ObscuraCLI](Sources/ObscuraCLI) | command execution과 JSON output | `obscura-swift` executable |
| [Sources/ObscuraCLIArguments](Sources/ObscuraCLIArguments) | pure CLI parsing | package-internal target |
| [Tests](Tests) | domain, protocol, process, fixture integration regression | test-only |
| [Scripts](Scripts) | fail-closed build, verification, packaging | repository maintenance |
| [Docs](Docs) | architecture, vendor, verification index | documentation |
| [Vendor/Obscura](Vendor/Obscura) | immutable external Rust snapshot | not a first-party public API |
