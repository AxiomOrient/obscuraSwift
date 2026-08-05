# Architecture

ObscuraSwift의 source of truth는 [Package.swift](../Package.swift), `Sources/`, `Tests/`, `Scripts/`다. 이 문서는 그 구현이 지키는 책임 경계와 실패 계약을 설명하며, vendored engine의 내부 API를 public contract로 만들지 않는다.

## 책임 분리

```text
Application
    │
    ▼
ObscuraKit public values and errors
    │
    ▼
BrowserSession actor ── SessionReducer
    │                  state + event → state + effects
    ▼
adapters: process · HTTP discovery · WebSocket
    │
    ▼
selected engine process: vendored Obscura or local Google Chrome
```

- `BrowserSession`은 session state, operation queue, engine process, CDP connection, snapshot subscriber를 격리한다.
- `SessionReducer`는 I/O, clock, socket, process를 호출하지 않는 pure transition이다.
- `CDPConnection`은 request ID, pending continuation, send phase, inbound frame validation을 소유한다.
- `CObscuraProcess`와 `EngineProcess`는 spawn, stdout/stderr drain, process group shutdown, reap을 담당한다.
- public API는 raw CDP, WebSocket transport, process descriptor, V8/remote object를 노출하지 않는다.

## Session lifecycle

```text
idle → starting → ready ↔ executing
                    │
                    └→ quarantined → recovering → closed

starting / ready / executing / quarantined / recovering
    → closing → closed
```

startup은 process launch, control-plane discovery, transport connection, protocol initialization으로 나뉜다. operation은 session actor의 bounded FIFO permit을 얻은 뒤 reducer 밖에서 CDP effect를 수행한다. navigation 또는 DOM mutation이 성공할 때만 generation이 증가한다.

이 경계는 모든 코드를 reducer나 actor로 바꾸지 않는다. lifecycle처럼 재현 가능한 업무 상태는 pure `SessionReducer`의 enum event로 전이한다. CDP request ID·pending continuation·send phase와 FIFO permit처럼 suspension 중에도 ownership이 필요한 상태만 각 actor가 소유한다. socket/process/CDP는 port와 adapter 밖으로 밀어내며, pending 등록과 `sending` 전이는 하나의 actor turn에서 끝낸다. 그 뒤 취소·timeout은 결과가 불명확하므로 연결을 종단한다. 따라서 효과를 추측해 재전송하지 않고, recovery는 새 session을 만드는 명시적 전이로만 수행한다.

`Locator`는 remote node ID를 보관하지 않고 `CSSSelector` recipe만 보관한다. navigation 뒤에도 stale remote handle을 public API로 만들지 않는다.

## Engine process boundary

`EngineExecutable` makes the launch choice explicit: the default is vendored
Obscura, `.explicit` is an Obscura-compatible executable, and `.chrome` starts
the supplied Google Chrome executable. Chrome mode uses `--headless=new`, a
fresh private temporary profile, and a loopback-only remote debugging port;
the profile is removed after a clean shutdown. Obscura-only stealth is rejected
for Chrome rather than silently ignored.

process adapter는 다음을 강제한다.

- child session/process group 분리와 stdin `/dev/null`
- stdout/stderr 동시 drain 및 bounded combined diagnostic tail
- CLOEXEC exec-failure pipe, inherited descriptor 폐쇄, `waitpid` reap
- SIGTERM grace 뒤 SIGKILL escalation
- Linux에서 `PR_SET_PDEATHSIG(SIGKILL)` 및 fork race 처리

정상 종료는 `BrowserSession.close()`가 권위 있는 lifecycle boundary다. owner가 live session을 버리거나 `stop()`이 실패하면 deinit/emergency path가 child containment를 시도하지만, 이는 정상 수명 관리의 대체물이 아니다.

## Discovery와 CDP session

control plane은 loopback `127.0.0.1` HTTP만 사용하고 다음을 검사한다.

- HTTP/1.1 200, JSON content type, 하나의 unsigned `Content-Length`, response size limit
- browser identity와 CDP protocol version
- Obscura의 정확한 browser WebSocket endpoint와 `page-1` target endpoint, 또는 Chrome의
  per-process browser/page endpoint

transport는 browser endpoint에만 연결한다. 초기화는 `Target.createTarget`으로 `page-1`을 만들고 flattened `Target.attachToTarget`으로 단일 `sessionId`를 확정한다. 이후 Page/Runtime/Network request에는 그 ID를 포함하며, response는 request와 같은 session이어야 한다. 알려지지 않은 response ID, 다른 session의 response/event, malformed frame은 terminal protocol violation이다.

vendored server의 두 compatibility defect는 adapter에서 좁게 처리한다.

- raw frame 안의 정확한 `"Browser.close"` sentinel은 method와 무관하게 connection을 닫을 수 있으므로, encoder는 그 sentinel의 첫 `B`만 의미가 같은 `\u0042` escape로 바꾼다.
- control plane은 `Accept: application/json` 안의 `/json`을 path처럼 해석할 수 있으므로 probe는 `Accept: */*`를 보내되 response content type은 계속 검증한다.

## Failure와 recovery

JavaScript exception, element not found, explicit CDP operation error, input validation error는 호출 단위의 비종단 오류다. engine exit, transport failure, protocol violation, dispatch 뒤 timeout/cancellation, reducer invariant failure는 session을 quarantine하고 resources를 종료하는 종단 오류다.

retry, fallback, silent recovery는 없다. recovery는 새 process와 새 connection을 launch한 뒤 non-expired cookie만 복원하는 명시적 작업이다. checkpoint는 compatibility와 cookie만 포함한다.

## Platform과 UI boundary

`Package.swift`는 macOS 13을 package platform으로 선언한다. POSIX layer는 Linux code path도 갖지만 Linux-specific parent-death evidence는 Linux host에서만 얻는다. platform claim과 실제 verification evidence는 [verification contract](VERIFICATION.md)에서 분리한다.

이 package에는 SwiftUI, Observation, TCA target 또는 UI adapter가 없다. core가 제공하는 UI-adjacent surface는 immutable `SessionSnapshot`의 `snapshots()` stream뿐이며, 상위 application이 이를 어떤 UI state model로 변환할지는 이 repository의 contract 밖이다.

핵심 기능이 state, event, effect, failure, regression test에 빠짐없이 연결되는지는 [core contract matrix](CORE_CONTRACT_MATRIX.md)로 추적한다.
