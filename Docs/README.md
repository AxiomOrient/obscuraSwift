# Documentation Index

이 폴더는 ObscuraSwift의 implementation guide가 아니라 repository contract index다. package product와 target은 [Package.swift](../Package.swift), 실제 동작은 source와 tests, 실행 가능한 검증은 `Scripts/`가 source of truth다.

| 문서 | 답하는 질문 |
|---|---|
| [Architecture](ARCHITECTURE.md) | session, process, CDP boundary가 어떻게 나뉘는가? |
| [Core Contract Matrix](CORE_CONTRACT_MATRIX.md) | 각 핵심 기능은 state/event/effect/failure/test에 어떻게 추적되는가? |
| [Vendored Obscura Policy](VENDORING.md) | 외부 Rust snapshot을 무엇으로 식별하고 어떻게 갱신하는가? |
| [Verification Contract](VERIFICATION.md) | 어떤 command와 evidence가 source/archive completion을 뜻하는가? |
| [Completion Report](../COMPLETION_REPORT.md) | 현재 작업본은 어느 gate까지 통과했고 무엇이 남았는가? |

upstream engine 자체의 CLI와 Rust API는 [`Vendor/Obscura/README.md`](../Vendor/Obscura/README.md)를 참고한다. 그 문서는 vendored external project의 문서이며 ObscuraSwift public API의 대체 문서가 아니다.
