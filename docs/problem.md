# ERC-6551P — the problem, with sources

What goes wrong when an NFT that owns an ERC-6551 account is sold, who has said so in public, and how ERC-6551P
answers each point. ERC-6551P is a **proposed extension of ERC-6551: a draft, not an accepted standard** (an ERC
number comes from the EIP editors). The reference implementation is not audited and not deployed.

Every source below was opened on 2026-10-29 or 2026-10-30, as its row says (the page itself, its raw markdown, the forum's JSON API, or the cloned
repository); quotes are copied from that text. Forum posts are cited by number:
`https://ethereum-magicians.org/t/erc-6551-non-fungible-token-bound-accounts/13030/<n>`. The residuals R-1…R-16 are in
`erc-6551p.md`, Security Considerations.

## The sources

| # | Source | Status / date |
|---|---|---|
| S1 | ERC-6551 "Non-fungible Token Bound Accounts", https://eips.ethereum.org/EIPS/eip-6551 (raw: https://raw.githubusercontent.com/ethereum/ERCs/master/ERCS/erc-6551.md) | **Review**, not Final; created 2023-02-23 |
| S2 | The ERC-6551 discussion thread, https://ethereum-magicians.org/t/erc-6551-non-fungible-token-bound-accounts/13030 | 2023-02-23 to now |
| S3 | ERC-5646 "Token State Fingerprint", https://eips.ethereum.org/EIPS/eip-5646 | Final |
| S4 | Tokenbound AccountV3 source, https://github.com/tokenbound/contracts (`src/AccountV3.sol`, `src/abstract/Lockable.sol`, `Permissioned.sol`, `Overridable.sol`, `execution/BatchExecutor.sol`); our copy and reading: `docs/tokenbound/`, the AccountV3 source | HEAD `bce75f9` (2024-03-11) |
| S5 | Zellic, "Tokenbound" security assessment (Aug 29 – Sep 8, 2023), https://github.com/tokenbound/contracts/blob/main/audits/Tokenbound%20-%20Zellic%20Audit%20Report.pdf | findings fixed per the report |
| S6 | ERC-7656 "Generalized Contract-Linked Services", https://raw.githubusercontent.com/ethereum/ERCs/master/ERCS/erc-7656.md | Final |
| S7 | ERC-1271 "Standard Signature Validation Method for Contracts", https://raw.githubusercontent.com/ethereum/ERCs/master/ERCS/erc-1271.md | Final |
| S8 | Qi et al., "Understanding NFTs from EIP Standards", arXiv 2508.07190, https://arxiv.org/pdf/2508.07190 | v1, 2025-08-10 (secondary) |
| S9 | RareSkills, "ERC-6551 Standard: Token Bound Accounts (TBA)", https://www.rareskills.io/post/erc-6551 | updated 2025-08-20 (secondary) |
| S10 | OneKey, "ERC-6551: How NFTs can own wallets", https://onekey.so/blog/ecosystem/erc-6551-how-nfts-can-own-wallets | updated 2025-10-16 (secondary) |
| S11 | The ERC-8216 thread "Slot-Based Equipment for ERC-6551 Accounts", https://ethereum-magicians.org/t/erc-8216-slot-based-equipment-for-erc-6551-accounts/28139 (3 posts, opened 2026-10-30) | a sibling proposal, 2026 |


**Incidents.** We found **no public incident** in which an approval, an operator or a signature survived the sale of
a token bound account and drained the buyer (10 web queries and a search of the Code4rena and Sherlock repositories,
2026-10-29). The ERC-6551 author asks for "real world examples" of deep ownership loops in S2 #232. The issues below
are design issues stated by the standard, its author, its reviewers and an audit, not reports of losses.

**Why ERC-6551 is not Final.** Its author, S2 #225 (2025-02-03): "How can marketplaces efficiently prevent
bait-and-switch scams involving TBAs? There have been a few potential solutions proposed so far (see discussions about
using state for this above), but they still have edge cases and have not been fully proven."

---

## 1. The last-second drain before a fill

**What goes wrong.** Alice lists an NFT whose account holds 10 ETH. Bob buys. In the same block, before Bob's fill,
Alice takes the 10 ETH out. Bob gets the NFT and an empty account.

**Sources.**
- S1, Security Considerations → Fraud Prevention, the same example ("Alice withdraws 10ETH from the token bound
  account, and immediately accepts Bob's offer … Bob receives token X, but account Y is empty"), and: "Preventing
  fraud is outside the scope of this proposal."
- S2 #80: "When the NFT is sold, the miner could prioritize a transaction to transfer the 1M ETH elsewhere before the
  atomic swap occurs." S2 #81 (author): marketplaces are responsible; a Seaport zone "can execute arbitrary validation
  logic after an order has been processed". S2 #230 (2026-02-06): "The “Bait-and-Switch” … remains a primary fraud
  vector."
- S3, Security Considerations: if the fingerprint misses a parameter, "The token owner would be able to change the
  state of the token before accepting an offer."
- S5, finding 3.2 (Critical, fixed): "A malicious seller … can list a locked and statecommitted NFT with a TBA that
  owns a valuable NFT, and then still, before finalizing a sale, execute anything on behalf of the valuable NFT’s TBA".
- S8, S9: the same scenario, secondary.

**Limits of the `state()` answer** (S1 suggests a commitment to the account's `state()`): S2 #206 (author): "The edge
case here is approval-based transfers, which would not change account state." S2 #212: buyers "still risk being
cheated because it’s so much harder to reason about". S2 #80: a seller can "add numerous fake assets to the linked
account". In AccountV3, `state()` does not change when an approved spender pulls or a permit is used (the AccountV3 source, read from `AccountV3.sol:260-296`).

**How ERC-6551P answers.**
- The **buyer** writes conditions (for example "the account holds ≥ 10 ETH"), and they are checked on the account
  **after** the NFT transfer, in the buyer's own transaction. A drain makes the whole fill
  revert. Three paths do this: the market's `buy` / `accept`, `checkedFill` of any Seaport order, and a zone order.
- A plain marketplace listing passes only while the token is **ready**: `readyToSell` was the last leg of an account
  batch in an EARLIER transaction and the account has not acted since. A drain ends readiness.
- A ticket of the market or the zone is bound to the account's `state()` at the opening, so no account batch can run
  between the opening and the transfer.

S2 #232 (author): "the ideal solution to this problem would prevent bait-and-switch style attacks without requiring
marketplace awareness at all." ERC-6551P does not reach that ideal: its ready path needs no marketplace change but
gives only Promise 1; Promise 2 needs a checked path.

**What stays.** R-3: on the plain ready path (a listing filled directly, a plain offer the seller fills) a seller can
drain and make the token ready again in an earlier transaction; the buyer gets no check of the contents there. R-13:
the value of a holding is not checked, only its amount; the tolerance share; holdings the front end cannot read.

## 2. Leftover approvals and operators after the sale

**What goes wrong.** Before the sale, Alice's account approves her own address to spend its USDC (or makes her an
operator of its NFTs). After the sale the approval is still there. Alice takes the USDC from Bob's account, and no
`state()` change shows it.

**Sources.**
- S2 #81 (author): "Approval-based transfers are an obvious edge case here". S2 #188 (author): "We’re working with
  marketplaces to determine the best approach to handling active approvals during trustless token transfers." S2 #206
  (author), above. S2 #182: "What is there to stop a third party approved operator from moving the assets thus
  avoiding increment of the nonce?"
- S2 #191: "the abundance of assets with different approval / operator methods - some of which may be unique to the
  tokens being used", and the idea of "a custom pre programmed 4byte list". S2 #193 (author): such a list "would come
  at the expense of compatibility with the existing ecosystem".
- S4: Tokenbound's own permissions and overrides are "keyed by the root owner address, so will be disabled upon
  transfer" (`Permissioned.sol`, `Overridable.sol`); token-level allowances and `setApprovalForAll` grants made by the
  account stay (read from the AccountV3 source).
- S10: "Approval carry‑over: If the TBA has lingering approvals … transferring the NFT hands those approvals to the
  buyer."
- S11 #3 (a review of a sibling proposal, 2026): "an owner could grant a third party standing approval rights on an
  equipped token contract via execute, sell the parent NFT, then the approved address drains everything after
  delivery." S11 #2, the same review: "An owner could construct an execute() call invoking safeTransferFrom directly
  on an equipped token’s contract, draining the underlying token". These are design findings of a review, not
  incidents.
- No source we opened names Permit2 allowances; they are a grant surface of the same kind.

**How ERC-6551P answers.** The seller keeps no right (Promise 1), on modeled surfaces:
- **No modeled grant at rest.** The account decodes every grant call it makes (ERC-20 allowances, ERC-1155 / ERC-6909
  / ERC-777 operators, ERC-6909 allowances, Permit2, listed lending authorizations), reads each grant before and after
  the batch, and reverts if one is higher at the end. A grant used up in the batch passes
  (approve → spend → reset).
- **No NFT approval and no NFT operator, ever.** An approved address or an operator of an NFT can make further rights
  that no read finds, so the account refuses them (the only operator it gives is on a proven plain
  ERC-1155, reset in the batch).
- **Refused rights with no read-back** (pre-signed orders, ERC-1820 managers, delegate.xyz delegations, v4
  subscriptions, and more): refused by selector and by target.

The 4-byte list of S2 #191 is close to this design. The cost S2 #193 names is real: the account itself cannot sell
NFTs on a marketplace; the agent uses its own wallet for that.

**What stays.** R-1 (a grant through a call the account cannot decode), R-5 (built-in grants no account action made),
R-6 (configuration rights not in the refused list), R-7 (value inside other protocols).

## 3. Signatures: value can leave without a change of `state()`

**What goes wrong.** ERC-6551 requires every account to validate signatures (S1: "All token bound account
implementations MUST implement ERC-1271 signature validation"). The owner can then sign for the account: a Permit2
transfer, an off-chain order, a permit. Such a signature moves the account's tokens through another contract, and the
account's `state()` does not change (in AccountV3, read from its source). A seller who promised "state X at the fill"
can sign a transfer out, use it, and still show state X.

**Sources.** S1 (the ERC-1271 MUST; `state()` "SHOULD be modified each time the account changes state"); S4 and
the AccountV3 source (AccountV3: `state()` changes only on `execute`, `lock`, `setPermissions`, `setOverrides`; "the lock
is not consulted in signature checks"); S7 (validity "could be context dependent (e.g. time based or state based)").
S5 §5.2 (threat model): "Being able to replay, inject, reorder, or modify existing signatures can also lead to loss of
funds".

**What we did NOT find.** No source we opened says that an OLD owner's signature stays valid after the sale. In the
ERC-6551 reference implementation and in AccountV3, `isValidSignature` checks the CURRENT owner when it is called (our
reading of the code), so an old owner's signature fails after the transfer. The issue is the path above: a signature
used before the fill, which a `state()` commitment does not see; and a signature already turned into an on-chain
allowance, which is issue 2.

S2 #218 (the ERC-6551 author): "Similarly isValidSignature and isValidSigner can always return invalid."

**How ERC-6551P answers.** The account gives **no signature of any kind**:
`isValidSignature` always returns `0xffffffff`, `isValidSigner` always returns 0, and the account has no key. So every
movement of value is an `execute` by the owner, and every `execute` changes `state()`. ERC-6551 permits
this: an account "MAY implement additional authorization logic which invalidates the holder as a signer" (S1).

**What stays.** The cost: no off-chain orders, permits or sign-in as the account; the owner's own wallet
signs for those.

## 4. The lock answer, and its cost

**What goes wrong.** One answer to issue 1 is a lock: the owner freezes the account until the sale ends. A frozen
account cannot act, so an agent that lives in it stops. And a lock does not close issues 2 and 3.

**Sources.**
- S1 lists it as a mitigation: "Implement a locking mechanism on the token bound account implementation that prevents
  malicious owners from extracting assets from the account while locked".
- S2 #237 (author, 2026-09-16): early versions of the proposal had a lock, but "there were several edge cases that
  this did not prevent (most significantly transfers using allowances) and it introduced a griefing mechanism (owners
  could lock accounts forever to prevent future owners from withdrawing)". S2 #232 (author): "The primary challenge to
  a lock mechanism is ensuring that all accounts implement it properly, and that account implementations that claim to
  be locked actually are."
- S4, `Lockable.sol`: a lock lasts up to 365 days; while it holds, `execute`, overrides, permissions and a new lock all
  revert. In the AccountV3 source, the lock survives a transfer, blocks the owner too, and "open approvals and ERC-1271
  signatures still work while locked".
- S5, finding 3.2: a nested account "can bypass locks and state changes" (fixed).

**How ERC-6551P answers.** No lock, freeze, escrow, wrapper or cooldown anywhere. Issues 1–3
are closed by the account rules and the checked sale instead. On the market and zone paths the agent keeps working
while its NFT is listed: the buyer's conditions are read at the fill, so readiness is not needed there.

**What stays.** A plain marketplace listing needs the token ready, so the agent stays idle until that fill.
That is a choice of the seller's path, not a lock: any account action ends readiness, and the agent can act again.

## 5. An owner change in the middle of a batch

**What goes wrong.** The owner's batch has several legs. One leg sells or moves the NFT (for example, through a
contract that the owner controls). Later legs still run with the old owner's authority, after the NFT has a new
owner.

**Sources.** We found **no public write-up** of this case. The nearest: S2 #203 (author): "In order to prevent
footguns in the case of reentrancy, the account should update the state prior to the external call"; S2 #110 (author):
"I don’t think there are reentrancy risks here"; S5 finding 3.5: the root owner can be changed "by transferring an NFT
in the chain to a victim"; S6: "Linked services … may be vulnerable to reentrancy exploits". From the code (S4): the
AccountV3 `executeBatch` checks the executor once, before the loop. This point is our own analysis, marked as such.

**How ERC-6551P answers.**
- The account checks `owner()` again after **every** leg, and reverts the whole batch if it changed (`OwnerChanged`).
- The account exposes `inBatch()`, and the collection refuses every non-owner transfer while the account's batch runs
  (`AccountInBatch`). A nested `execute` reverts (`Reentered`).
- No `DELEGATECALL`, no `CREATE` from the account.

**What stays.** R-10: an owner whose control changes without a transfer of the NFT (a Safe owned by another NFT's
account, an NFT-gated EIP-7702 delegate) is outside what the collection can see.

## 6. Ownership cycles, and an account that sells another account

**What goes wrong.** (a) An NFT moves into its own account, or into a chain of accounts that leads back to it: no one
can ever act again, and the assets are lost. (b) Alice's account A holds the NFT of account B. Alice lists B. Before
the fill she acts through A and B, or she sells A, and the control of B changes without a transfer of B's NFT.

**Sources.**
- S1, Ownership Cycles: "All assets held in a token bound account may be rendered inaccessible if an ownership cycle
  is created", and depth > 1 "is difficult to enforce … and as such is outside the scope of this proposal".
- S2 #25, #127; S2 #129 (author): cycles "allow for interesting burn mechanics", so the proposal does not prevent
  them. S2 #230: a claim of "Deep Loop" chains made to grief tools; S2 #232 (author) asks for examples.
- S4: AccountV3 `onERC721Received` reverts `OwnershipCycle` for its own token only (depth 1).
- S5, finding 3.2 (nested accounts and the sale, above); S5 §5.2: "very long ownership chains could prove to be too
  costly to verify".
- S6: "Smart wallets linked to NFTs that are then held by the same wallet can create ownership cycles".
- No source we opened treats "an ERC-6551 account as the seller" as a separate risk; part (b) is our own analysis
  built on S5 3.2 and 3.5.

**How ERC-6551P answers.**
- No token of the collection may move into an account of ANY implementation bound to a token of the same collection
  (`AccountedERC721._isOwnAccount`), and the account refuses its own NFT in `onERC721Received`. One case stays open:
  an address with no code cannot be recognised, so an owner can burn its own token by sending it to its own future
  clone (R-16). Nobody can force this on a holder.
- The **seller may not be an ERC-6551 account** on any sale path, and `readyToSell` refuses an owner that is one
  (the market and the zone check it too). Such an account moves the NFT out with its own transfer
  first, and then sells.

**What stays.** R-8 (NFTs of other collections with their own wallets, inside the account), R-10 (owners that are not
registry clones but whose control changes without a transfer), R-15 (a cycle through another collection's account:
two owner transfers make both accounts unusable; a burn by the owner). Also R-14: anyone can create other accounts for
the same token (S2 #97: "any NFT can have an unlimited number of addresses using an unlimited number of
implementations / salts"); the promises cover only the canonical account.

---

## Summary table

| # | Issue | Main sources | ERC-6551P answer | Residuals |
|---|---|---|---|---|
| 1 | Drain before a fill | S1, S2 #80 #81 #225 #230, S3, S5 3.2 | buyer conditions after the transfer (market, `checkedFill`, zone); readiness from an earlier tx; tickets bound to `state()` | R-3, R-13 |
| 2 | Leftover approvals and operators | S2 #81 #182 #188 #191 #193 #206, S4, S10 | no modeled grant at rest; no NFT approval or operator; refused rights | R-1, R-5, R-6, R-7 |
| 3 | Signatures move value with no `state()` change | S1, S4, S7, S5 §5.2 | no signatures of any kind | (cost only) |
| 4 | The lock and its cost | S1, S2 #232 #237, S4, S5 3.2 | no lock; the agent keeps working on the checked paths | plain listing needs readiness |
| 5 | Owner change mid-batch | no write-up; S2 #110 #203, S5 3.5, S4 code | owner re-check after every leg; `inBatch()`; no sale in a batch | R-10 |
| 6 | Cycles; an account as the seller | S1, S2 #25 #127 #129 #230 #232, S4, S5, S6 | no-nesting of any implementation; seller is not an ERC-6551 account | R-8, R-10, R-14, R-15, R-16 |
