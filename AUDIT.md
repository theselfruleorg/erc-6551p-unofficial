# Audit status

**This code has no outside audit.** No security firm has reviewed it. An outside audit is planned, and it will not be
complete before the first deployment. Every review below is an AI-assisted review, a static analysis tool or a fuzzer.
These reviews are **not an audit**, and they do not prove that the code has no bug. Do not use this code to hold value
that you cannot lose.

This page lists every review of the contracts in this repository: what it read, what it found, what changed, and what
no review has read yet. The reviews ran in the private development repository of the first deployment, so this page
cites dates and test names, not commit hashes. The same runs also read contracts of the first deployment that are not
in this repository (its sale, pool and art contracts); those findings are left out here.

## 1. In short

| Question | Answer |
|---|---|
| Outside audit | **None yet.** Planned; not complete before the first deployment. |
| Reviews of this code | 10 runs from 2026-10-13 to 2026-11-12 (§2): AI-assisted reviews, Slither, Aderyn, Medusa |
| Findings fixed | Every finding of a defect in this code is fixed, each with a test (§3). |
| Open by design | One: a new readiness brings back old plain listings (§4, item 1). |
| Not read by any review | The two latest refusal changes (K-94, K-95) and the documentation changes of 2026-11-12 (§5). |
| Leads not triaged | Many low-confidence leads and every static-tool Low (§4, item 4). |
| Theft by a stranger | No review found a path. That is not a proof that none exists. |

## 2. The reviews

| # | Date | Method | What it read | Result for this code |
|---|---|---|---|---|
| R1 | 2026-10-13 | AI-assisted review (Pashov `solidity-auditor`), 3 passes × 12 agents | the early collection base and journal (before this account existed) | No finding in today's code; the findings were about an older account design, which was replaced. |
| R3 | 2026-10-28 | AI-assisted design review of the specification text, before the code | the specification | 30 design findings; all fixed in the text before the code was written. |
| R4 | 2026-10-28 | AI-assisted validation pass of the first code | account, collection rule, market, zone | No Critical or High. P4-01 (a journal leg after the ready leg), P4-03 (a Permit2 extension), P4-04 (a zone listing always reverted), all Medium: fixed with tests. |
| R5 | 2026-10-28 | AI-assisted review, 1 pass × 12 agents, 21 files | account, conditions, market, zone, collection base, journal | P4-12 (High): the ticket of `checkedFill` brought back old plain listings. Fixed: `checkedFill` opens no ticket of its own, so a plain listing needs readiness. |
| R6 | 2026-10-29 | Final check before the first build | the full stack | Gas sizing (an account call needs more gas than it uses): now a documented rule, `eth_estimateGas` only. |
| R7 | 2026-10-30 | AI-assisted review, 3 passes × 12 agents | account, conditions, market, zone, collection rule, collection base, example | F-1: some protocol writes were not refused (Euler EVC, Maker, Superfluid). F-3: the draft allowed a repeating `state()`. F-4: ERC-7674 `temporaryApprove` was not read back. F-5: a one-argument `approve(address)` was not read back. F-6: more writes with no read-back. All fixed. F-7: the approve probe blocks WETH9 on Ethereum and Base: accepted, documented. |
| R8 | 2026-11-06 | Slither 0.11.6, Aderyn 0.6.8, Medusa 1.5.1, in an offline container | all sources (static); the account and the collection rule with a mock token (Medusa) | No real bug in the High and the money-path Medium items. 8 of 8 fuzz properties held over 2,168,627 calls; a canary property failed on purpose, so the run reaches real sales. The Lows were not triaged. |
| R9 | 2026-11-06 | AI-assisted review, 3 passes × 12 agents, 24 files | every contract here except the interfaces | F-C: owed ETH could be paid only to its caller. Fixed: `claim(address who)`. F-B: see §4. A token sent to its own future clone: now residual R-16, with a test. |
| R10 | 2026-11-06 | AI-assisted review, 1 pass × 12 agents | the same files | F-F: Tokenbound `setPermissions` / `setOverrides` written through the account survive a sale. Fixed (K-93). |
| R11 | 2026-11-09 | AI-assisted review, 3 passes × 12 agents | the same files | F-G: Tokenbound `lock(uint256)` was not refused. Fixed (K-94). F-B recorded again at its root. Pass 3 still found new leads: the search has not fully converged. |
| R12 | 2026-11-12 | AI-assisted documentation review and a residual check (not a code audit) | the documents against the code; the refused list against common protocols | Errors in the documents, fixed the same day. New residual cases named (§4, item 3). No code change. |

(R2 was a validation of the first deployment as a whole; its contract items were about that deployment's own contracts.)

## 3. Fixes and their tests

Every fix has a test that failed before the fix. The tests are in `test/`.

| Finding | Fix | Test |
|---|---|---|
| P4-12 old listing through `checkedFill` | `checkedFill` opens no ticket of its own | in the market suite (not in this repository yet, §6) |
| R7 F-1 protocol writes not refused | refused | `Account.t.sol::test_K84_operatorSiblingsAndProtocolWrappersRefused` |
| R7 F-4 ERC-7674 | read back | `Account.t.sol::test_K88_erc7674TemporaryApproveIsAModeledGrant` |
| R7 F-5 one-argument approve | read back | `Account.t.sol::test_K89_dsTokenSingleArgumentApproveIsAModeledGrant` |
| R7 F-6 more rights with no read-back | refused | `Account.t.sol::test_K90_moreRightsWithNoReadBackRefused` |
| R9 F-C owed ETH | `claim(address who)` | `ERC6551PCornerSale.t.sol::test_K91_anyCallerPaysTheOwedPayee` |
| R9 lead: own future clone | residual R-16 | `ERC6551PCorner.t.sol::test_K92_tokenSentToItsOwnEmptyCloneIsAnOwnerMadeBurn` |
| R10 F-F Tokenbound permission writes | refused | `Account.t.sol::test_K93_tokenboundPermissionWritesRefused` |
| R11 F-G Tokenbound lock | refused | `Account.t.sol::test_K94_tokenboundLockRefused` |
| ERC-8004 agent wallet writes (design change, not a finding) | refused | `Account.t.sol::test_K95_agentWalletWritesRefused` |

## 4. What stays open

1. **A new readiness brings back old plain listings (R9 / R11 F-B, open by design).** Readiness is not bound to one
   listing. If a seller makes a token ready again, every older plain listing of the same owner can fill again at its
   old price. No contract can bind a plain marketplace order, so the fix is in the front end: a Sell flow cancels the
   older orders before a new readiness. Market and zone listings are not affected.
2. **The residuals R-1 to R-16** (the draft, Security Considerations). They are the named limits of the design, not
   bugs. The account can call any contract, so no list of refused or read-back rights can be complete: a right that a
   contract stores for the account behind a call that the account does not know is not covered (R-1, R-6).
3. **Cases named on 2026-11-12 (R12), inside R-6 and R-8, with no code change yet:**
   - A Safe that has the account as an owner accepts the account's own `execTransaction` with no signature. A seller
     can add an owner, a module or a guard before the sale, and keep the Safe after it.
   - A rewards receiver or a claimer (for example a Curve gauge `set_rewards_receiver`, an EigenLayer
     `setClaimerFor`) can send the future yield of the buyer's holdings to the seller.
   - An inner Tokenbound AccountV3 can write its own permissions through its own DELEGATECALL, so the refusals of
     K-93 and K-94 stop only a direct call.
   These rights are used after the sale, so a checked sale does not stop them either. A refusal in the account is
   possible for the first two; it is a code change, and no review has read one yet.
4. **Leads not triaged.** The AI-assisted runs also returned low-confidence leads (68 in R9, 46 in R10, 58 in R11;
   many repeat). The ones that a fix closed are closed; the others are not proven wrong. Every Slither and Aderyn
   Low is untriaged. Examples that touch this code: the payee of the market can return large data inside its 50,000
   gas and make the buyer pay more gas (the account's own calls have the same pattern); readiness ends with no event.
5. **Gas figures** in the docs were measured on 2026-10-29, before the refusals K-84 to K-95. Measure your own build.

## 5. What no review has read

- **K-94** (Tokenbound `lock` refused, 2026-11-09) and **K-95** (ERC-8004 `setAgentWallet` / `unsetAgentWallet`
  refused, 2026-11-10). Each adds one or two refused selectors, with a test.
- **The fuzzer** (R8) ran before F-C, K-92, K-93, K-94 and K-95.
- **The comment and documentation changes of 2026-11-12.** No code behaviour changed.
- **The tests and the test base of this repository** were never in a review's scope.
- **The interfaces** were read only by the static tools.

## 6. What the tests cover

| In this repository (offline, mocks and the real ERC-6551 registry bytecode) | Tests |
|---|---|
| `Account.t.sol`: the account, every refused and read-back surface, 5 fuzz tests | 65 |
| `AccountInvariant.t.sol`: no standing grant, `state()` never repeats, owner and signatures | 3 invariants |
| `ERC6551PExample.t.sol`, `ERC6551PCorner.t.sol`, `ERC6551PCornerSale.t.sol`: the sale rule and the checked sale on example collections | 46 |

Not in this repository yet: the market and zone suites (35 tests), the sale-rule suite on the first deployment's
collection (23 tests), the fork tests on real protocols, the real Seaport 1.6 gate (20 of 20 pass on forks), and the
fuzz harness. Known gaps in all tests: no real Safe or ERC-4337 wallet as the owner; no Dutch-auction order or partial
fill through `checkedFill`; no zone order across two collections.

## 7. How to report

Read [`SECURITY.md`](SECURITY.md). A report goes by email, not in a public issue. This page will list the outside audit
and each of its findings when it exists.
