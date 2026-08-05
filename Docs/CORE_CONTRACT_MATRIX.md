# Core Contract Matrix

이 매트릭스는 기능을 늘리기 위한 backlog가 아니라, 현재 제품의 핵심 기능이 상태·이벤트·effect·실패·검증 중 어느 하나에서도 유실되지 않게 하는 추적표다. source와 test가 source of truth이며, 이 문서는 변경 검토 때 그 연결을 빠르게 확인하는 index다.

| 핵심 기능 | 상태·이벤트의 소유자 | effect / 외부 경계 | 실패 계약 | 회귀 증거 |
|---|---|---|---|---|
| launch와 ready 전이 | `SessionReducer`: `startRequested` → `processLaunched` → `controlPlaneDiscovered` → `transportConnected` → `protocolInitialized` | `BrowserSession`, `EngineProcessHandle`, `EngineControlPlane`, `WebSocketTransport` | startup 실패는 cleanup 뒤 typed error | `testReducerExecutesExplicitStartupStateMachine`, startup/early-exit integration tests |
| loopback control-plane response | pure HTTP framing/validation helpers; retryable connect/deadline만 `LoopbackEngineControlPlane`이 보유 | loopback HTTP probe | malformed framing은 즉시 거부, 유효하지만 상한을 넘는 응답은 `oversized`, 의미 오류는 재시도하지 않음 | `testControlPlaneRejectsDeclaredResponseLargerThanConfiguredLimitWithoutRetrying`, malformed/duplicate/header tests |
| browser CDP handshake | startup의 `initializingProtocol` stage | `VendoredObscuraSessionBootstrap`: create target, flattened attach, enable domains, browser version | target/session response가 정확하지 않으면 protocol violation | `testVendoredBootstrapCreatesExactlyOneScopedPageSession`, actual runtime doctor |
| request correlation과 session isolation | `CDPConnection` actor의 request ID, pending request, adopted page session, `sending → sent` phase | `WebSocketTransport` send/receive | unknown ID, mismatched session, malformed event/frame, pending send 이후 timeout/cancellation은 terminal; request는 재전송하지 않음 | `ProtocolTests`의 response/session/event/timeout/cancellation cases, `testCancellationDuringSendTerminatesWithoutRetryingTheFrame` |
| one-at-a-time user operation | `SessionReducer`: `ready` ↔ `executing`; `BrowserSession` actor의 FIFO permit과 waiters | page-scoped CDP calls | queue limit은 `sessionBusy`; queued cancellation은 dispatch 없이 끝남; terminal dispatch failure는 quarantine | `testConcurrentCallsAreSerializedAndQueueLimitFailsExplicitly`, `testCancellingQueuedOperationPreventsCDPDispatch` |
| navigation과 DOM mutation | `SessionOperation.navigate` / `.mutateDOM`, generation counter | `Page.navigate`, `Runtime.evaluate` | input/JS/element error는 operation-local; malformed engine value는 protocol terminal | `testCoreNavigationEvaluationLocatorAndMutationContract`, URL/locator tests |
| cookie와 checkpoint | immutable `Cookie`, `SessionCheckpoint`, compatibility value | `Network.getAllCookies` / `Network.setCookies` | malformed/duplicate/invalid cookie는 dispatch 전 거부; restore는 non-expired cookie만 | cookie postcondition·checkpoint·recovery tests |
| supervision, close, recovery | `quarantined` / `recovering` / `closing` / `closed`, explicit `SessionEvent` | process stop, connection close, replacement launch | engine/transport failure는 quarantine; close는 terminal; recovery는 새 session만 반환하고 `recovering` 중 중복 replacement는 거부 | process-exit, close race, recovery integration tests, `testConcurrentRecoveryCreatesOnlyOneReplacement` |
| snapshot observation | immutable `SessionSnapshot` emitted after reducer transition | `AsyncStream` only | stream은 closed state에서 finish; UI behavior는 package 밖 | snapshot stream integration test |
| vendored engine supply chain | Swift state machine 밖의 immutable boundary | `Scripts/verify-vendor.sh`, locked Cargo build, actual runtime verifier | vendor mutation·symlink·ambient build substitution은 fail-closed | `verify-vendor.sh`, `build-vendored-obscura.sh`, `verify-runtime.sh` |

## 경계 규칙

- reducer는 pure function으로 남는다. I/O, task spawn, timer, process, socket은 reducer에 넣지 않는다.
- actor는 shared mutable lifecycle 또는 message correlation이 있는 곳에만 쓴다. 값 타입과 stateless protocol mapping은 actor가 아니다.
- `BrowserSession`의 permit/waiter는 reducer에 넣지 않는 scheduler 상태다. 입장, 취소, release 뒤 재검증만 actor가 소유하며, 외부 CDP dispatch는 permit을 얻은 뒤 한 번만 시작한다.
- `CDPConnection`의 pending continuation과 send phase는 transport 효과의 확정 여부를 구분하기 위한 actor 상태다. pending 등록과 `sending` 전이는 하나의 actor turn에서 끝내며, 그 뒤 취소·timeout은 연결을 종단해 재전송을 금지한다.
- `VendoredObscuraSessionBootstrap`은 vendor CDP request sequence만 안다. `BrowserSession`은 resource ownership, reducer event, supervision을 계속 소유한다.
- UI reducer, TCA effect, Observation model은 이 package에 존재하지 않는다. 상위 application이 `SessionSnapshot`을 변환할 수 있지만 core event/state와 역의존하지 않는다.
- Rust engine은 external immutable process다. Rust ownership/task/channel model을 Swift domain으로 복제하거나 vendor source를 수정하지 않는다.

## 변경 검사

핵심 기능을 추가·삭제·변경할 때는 해당 행의 state/event, external boundary, failure contract, regression evidence를 함께 갱신한다. 행에 대응하는 것이 없으면 기능 범위를 넓히기 전에 ownership과 failure model을 먼저 결정한다.
