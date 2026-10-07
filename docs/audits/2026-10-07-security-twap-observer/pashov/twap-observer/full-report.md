# 🔐 Security Review — frontier-extensions

---

## Scope

|  |  |
| --- | --- |
| **Mode** | filename |
| **Files reviewed** | `./contracts/twap-observer/TwapObserver.sol` · `./contracts/twap-observer/ITwapObserver.sol` |
| **Confidence threshold (1-100)** | 75 |

---

## Findings

_None — this scan raised no findings._

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **record reverts where its NatSpec says it does nothing** — `TwapObserver.record` — Code smells: NatSpec says "does nothing otherwise"; the code reverts `PoolNotBound` and `PoolNotGraduated`, and an ungraduated pool always has `count == 0` — A keeper that batches `record` calls without try/catch loses the whole batch on one unbound or ungraduated pool; no such keeper exists in the codebase.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and onchain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
