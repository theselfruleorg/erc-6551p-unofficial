# ERC-6551P — the full guide

ERC-6551P is a **proposed extension of ERC-6551: a draft, not an accepted standard** ("ERC-6551P" is a working name;
an ERC number comes from the EIP editors). The reference implementation in this repository is built and tested,
**not audited, not deployed**.

This guide goes from simple to exact. The exact text is the draft (`erc-6551p.md`). Where this guide and the draft
differ, the draft wins. Names in `code` are the names in the code (`reference.md` lists them all).

Contents: 1 the problem · 2 the two promises · 3 the account · 4 the collection rule · 5 the checked sale · 6 the life
of a token, path by path · 7 who does what · 8 what it costs · 9 what is not covered · 10 the gas rule · 11 FAQ.

---

## 1. The problem

ERC-6551 gives every NFT its own account (a wallet). Whoever owns the NFT controls the account. So when you buy the NFT,
you buy the account and what it holds. ERC-6551 leaves the sale out of its scope ("Preventing fraud is outside the scope
of this proposal"). Two things go wrong:

1. **Rights that the seller made survive the sale.** Before the sale, the account approved a spender, made an operator,
   or signed a permit. After the sale, the right still works. The seller takes the tokens from the buyer's account.
2. **The account is emptied just before the fill.** The buyer sees 10 ETH in the account and pays. In the same block,
   before the fill, the seller takes the 10 ETH out. The buyer gets an empty account.

A lock does not fix this. A locked account cannot act, so an AI agent that lives in it stops. And allowances and
signatures still work while the account is locked. The ERC-6551 author says the same about the early lock (thread post
237). The sources for every point are in `problem.md`.

## 2. The two promises

ERC-6551P makes two promises, and only these two. Their exact scope is in the draft.

**Promise 1 — the seller keeps no right** (G1). After the NFT changes hands, the previous owner,
and anyone that owner named, holds no right over the account's own holdings on the **modeled surfaces**: the seller
cannot take anything back through a right that the account knows. It holds on
**every** sale path, also a plain marketplace fill.

- The modeled surfaces: the account itself (only the current owner can make it call); ERC-20 allowances; ERC-1155,
  ERC-6909 and ERC-777 operators; ERC-6909 allowances; Permit2 allowances; the lending authorizations the deployment
  lists. The account reads each of these grants back.
- The account never gives an NFT approval or an NFT operator (an approved address could make more rights that no read
  finds), and never gives a signature.
- The account refuses a fixed list of rights that it cannot read back (pre-signed orders, delegation registries,
  position subscriptions, Tokenbound permission, override and lock writes, the ERC-8004 agent wallet, and more; the
  full list is in the draft §1.10).

**Promise 2 — you get what you checked** (G2). On a **checked path**, the sale fills only if every condition that
the **buyer** wrote holds on the account **after** the NFT transfer, in the same transaction. A failed condition
reverts the whole fill: the buyer keeps the money.

- The checked paths: the market's `buy` and `accept`, the market's `checkedFill` of any Seaport order, and an order of
  the zone.
- **Promise 2 does not hold on the plain path** (an ordinary marketplace listing filled directly, or a plain offer that
  the seller fills). There, a dishonest seller can empty the account and make it ready again in an earlier
  transaction. Promise 1 still holds there.

Both promises speak of the **canonical account** of a token (the registry clone of the collection's implementation,
salt 0). Everything outside the two promises is on one named list, R-1…R-16 (section 9).

## 3. The account

An ERC-6551P account is an ordinary ERC-6551 account: a 173-byte clone made by the canonical ERC-6551 registry
(`0x000000006551c19487814612e58FE06813775758`), with the standard footer `(salt, chainId, tokenContract, tokenId)`. It
keeps the AccountV3 shapes of `execute` and `executeBatch`. Its rules:

| Rule | What it means |
|---|---|
| Owner only | Only `ownerOf(tokenId)` on this chain can call `execute` / `executeBatch`. On another chain id, `owner()` is `address(0)`, so nobody can. No executors, permissions, overrides, plugins, sessions, guardian, upgrade or ERC-4337 entry point. |
| CALL only | `operation` must be 0. No `DELEGATECALL`, `CREATE`, `CREATE2`. A leg may not call the account itself. |
| One batch at a time | A transient flag is set for the whole batch. `inBatch()` returns it. A nested `execute` reverts (`Reentered`). |
| State changes every batch | `state()` changes at the start of every batch and never returns an old value (a hash chain), so any action shows. A deposit does not change it. |
| The owner is checked after every leg | If a leg moves the NFT to someone else, the whole batch reverts (`OwnerChanged`). |
| No signatures | `isValidSignature` always fails; `isValidSigner` always returns 0; the account does not claim ERC-1271. |
| No grant at rest | The account decodes every grant call it makes (also inside the known `multicall` / `batch` wrappers), reads each grant before and after the batch, and reverts if one is higher at the end (`StandingGrant`). Approve → spend → reset in one batch passes. |
| No NFT approval, no NFT operator | `approve(a ≠ 0, ·)` on an NFT-like target and `setApprovalForAll(·, true)` revert (`Refused`); the one exception is a proven plain ERC-1155, and that operator must be reset in the same batch. A revocation always passes. |
| Refused rights | A fixed list of selectors and targets that store rights with no read-back reverts (`Refused`): every canonical Seaport, CoW pre-signatures, Safe `approveHash`, ERC-1820, delegate.xyz v1 and v2, v4 `subscribe`, ERC-4907 users, and more (the draft §1.10). |
| Its own NFT | The account refuses to receive its own token (`OwnershipCycle`). |
| `readyToSell` is last | A leg that calls `readyToSell` may be followed only by journal entries (`JOURNAL.log`, no value), else `ReadyNotLast`. |
| Gas held back | The account holds back gas for its checks after each leg. A call needs more gas than it uses (section 10). |

What follows from these rules: every movement of value out of the account is an `execute` by the owner, and every
`execute` changes `state()`. So "the owner and `state()` are unchanged" means "nothing left the account" on the
modeled surfaces. The collection rule and the tickets rely on exactly this.

## 4. The collection rule

An ERC-6551P collection is an ERC-721 whose every token owns an ERC-6551P account. The kit gives it as an abstract
contract, `ERC6551PCollection` (on `AccountedERC721`), that any ERC-721 can inherit.

**The rule.** The owner's own transfer and the mint are free. Every other transfer (by an approved address, an
operator, a marketplace conduit, the market) passes only when **all** of these hold:

1. the token's account is not inside a batch (`AccountInBatch`);
2. the seller (`from`) is not an ERC-6551 account of any implementation (`SellerIsAccount`): the control of an
   account-held NFT can change without a transfer of that NFT, so no readiness or ticket can be trusted for it;
3. **either** the token is **ready** — `readyToSell` was the last leg of an account batch in an **earlier**
   transaction, by the same owner, and the account's `state()` has not changed since — **or** a one-use **ticket** of
   the market or the zone matches (`from`, `to`, the account's current `state()`); the transfer uses the ticket up.
   Otherwise `SaleNotReady`.

**Readiness** is how a token sells on any marketplace with no marketplace change. Any account batch ends it (the state
changes); any transfer ends it; `cancelReady` ends it. A ready record made in the same transaction does not count, so
a seller cannot drain and re-ready inside the fill. Readiness is not bound to one listing: a new `readyToSell` makes
every older plain listing of the same owner fillable again at its old price, so cancel old orders first.

**A ticket** is how the market and the zone sell a token while its agent keeps working. The market or the zone opens
the ticket in the buyer's transaction, bound to the account's `state()` at that moment; so no account batch can run
between the opening and the transfer. A ticket lives in transient storage (EIP-1153): it serves at most one transfer
and never outlives the transaction. It lives in the collection's own storage, so a ticket of one collection never
reaches another collection that shares the market (`test_K70_aTicketOfOneCollectionDoesNotReachAnother`).

**No nesting.** A token may not move into an account (of any implementation, any salt) of a token of the same
collection on the same chain (`OwnershipCycle`). One case stays open: an address with no code yet (R-16).

**Counts and fingerprint.** `transferCount(id)` goes up by one on every transfer with `from ≠ 0` (also a transfer to
yourself). A listing signs the count, so it dies when the token moves and comes back. The ERC-5646 fingerprint is
`keccak256(owner, transferCount, account.state())`: it means "the same owner, no transfer and no account action
since". It does not change on a deposit or on value that moves inside another protocol; for the contents, use
conditions.

## 5. The checked sale

### 5.1 Conditions

A condition is one check on the sold token's account, after the transfer:
`Condition(uint8 kind, address target, uint256 id, uint256 min, bytes data)`.

| Kind | Holds when |
|---|---|
| `ETH` | the account's ETH ≥ `min` |
| `ERC20` | `balanceOf(account)` ≥ `min` |
| `ERC721` | `ownerOf(id) == account` and no approval on it |
| `ERC1155` / `ERC6909` | `balanceOf(account, id)` ≥ `min` |
| `MINT_POSITION` (relative, optional) | the collection's `positionOf(soldId)` is a v4 position the account owns, with liquidity ≥ `min`, no approval, no subscriber |
| `V4POSITION` | the same for position `id`, and its pool hook is the hook the buyer names |
| `IDENTITY` (relative, optional) | the collection's ERC-8004 identity of the sold token is owned by the account, not approved, and its wallet is the account |
| `STATE` | `account.state() == min` |
| `CALLEQ` / `CALLGE` / `CALLLE` | a read of `target` with `data` returns exactly 32 bytes, `==` / `≥` / `≤` `min` |

The market or the zone **computes the account itself** from (collection, id) with its own pinned implementation; it
never takes the collection's word. Every read is a STATICCALL with a gas cap; a failed read fails the condition. A
collection that has no `positionOf` / `hasIdentity` makes the relative kinds fail (never a false pass,
`test_K75_relativeKindsFailClosedOnACollectionWithoutThem`). An unknown kind fails.

**The buyer-conditions rule.** Every checked fill needs at least one condition that the **buyer** wrote, and reverts
if one fails. A seller's promise can be carried and checked too, but it protects nobody: a seller can always write a
promise that holds. A payment into the sold account cannot make a balance condition true: `buy` and `accept` pay the
seller and the royalty only after the check, and `checkedFill` and the zone revert if a Seaport payment goes to the
sold account.

### 5.2 The market (`ERC6551PMarket`)

The market has no owner, no fee, no setter, and holds no NFT and no buyer funds at rest. It serves any collection that
names it (`collection.MARKET() == market`).

- `buy` — the buyer fills the seller's signed listing. The market takes the payment, opens a ticket, moves the NFT,
  checks the buyer's conditions on the account, closes the ticket, then pays the seller and the royalty.
- `accept` — the seller fills a buyer's signed offer; the buyer's conditions are bound in the signed offer.
- `checkedFill` — the buyer fills **any** Seaport 1.6 listing of one NFT through the market, and the market checks the
  buyer's conditions after the transfer. A plain listing still needs the token ready; a zone listing gets its ticket
  from the zone.

### 5.3 The zone (`ERC6551PZone`, Seaport 1.6)

A restricted Seaport order (order type 2 or 3) that names the zone. In `authorizeOrder` the zone opens the ticket; in
`validateOrder`, after the transfers, it checks the conditions and closes the ticket. A listing carries
`zoneHash = keccak256(abi.encode(transferCount, promise))` and the buyer's conditions in `extraData`; an offer binds the
buyer's conditions in `zoneHash`.

## 6. The life of a token, path by path

Every token: **mint** (the account is created in the same call) → **use** (the owner, or an agent that owns the NFT,
acts through `execute`) → **list** → **sell** → **buy** → the new owner uses it.

| Path | The seller | The buyer | The agent while listed | Promise 2 |
|---|---|---|---|---|
| A. Market listing → `buy` | signs a `Listing` (EIP-712, from the owner's wallet; never the account); approves the market once | calls `buy` with its conditions | keeps working | yes |
| B. Market offer → `accept` | calls `accept` | signs an `Offer` with its conditions | keeps working | yes |
| C. Zone listing (Seaport, restricted) | signs a Seaport order with the zone and `zoneHash` | fills with `fulfillAdvancedOrder` (or `checkedFill`) and its conditions in `extraData` | keeps working | yes |
| D. Zone offer | fills the buyer's restricted offer | signs the offer, conditions bound | keeps working | yes |
| E. Plain listing → `checkedFill` | makes the token ready, then lists on any Seaport marketplace | fills through `checkedFill` with its conditions | idle (an action ends readiness and pauses the listing; a new readiness brings it back) | yes |
| F. Plain listing → direct fill | as E | fills on the marketplace directly | idle | **no** (R-3) |
| G. Plain offer the seller fills | ready, then fills | signed a plain offer | idle | **no** (R-3) |
| H. Owner push (the owner's own transfer to a contract that pays) | — | the buyer contract | — | **no**: not a sale under the rule (R-11) |

On every path, Promise 1 holds. Front ends SHOULD use A–E only, and fill listings through `checkedFill`.

## 7. Who does what

**A seller.** Choose a path. For a plain marketplace listing, make the token ready as the last leg of an account batch
(the agent stops acting until the fill; any action ends readiness, and the listing cannot fill until the token is
ready again. A new readiness also brings back every older plain listing of the same owner, so cancel the old ones
first). For a market or
zone listing, sign the order; the agent can keep working, and the buyer's conditions decide at the fill. Never sell
from an ERC-6551 account: move the NFT to a plain wallet first.

**A buyer.** Use a checked path. Add a condition for **every** holding you care about (a good front end adds one for
every holding it finds, within a cap per fill so the fill stays under the gas limit). Simulate the fill from your own address before you sign. A holding whose condition fails in the
simulation cannot be checked: count it as worth 0. Conditions check amounts, not value: a seller can fill the account
with a worthless token.

**An agent operator.** The agent acts through `execute` / `executeBatch`. Approve → spend → reset to 0 in one batch.
Never leave an allowance. Do not try to approve an NFT, make an NFT operator, sign as the account, or call a
marketplace from the account: these revert; use the agent's own wallet. Size the gas with `eth_estimateGas`
(section 10). Put `readyToSell` as the last leg, only followed by journal entries.

**A marketplace or wallet.** Read `saleReadyOf(id)`, `transferCount(id)` and `getStateFingerprint(id)`. Show a plain
listing as "ready" only while `saleReadyOf` is true. Fill through `checkedFill` and build the buyer's conditions from a
fresh read of the account. Simulate first. Details: `integration.md`.

## 8. What it costs

- No standing approvals: an agent approves, spends and resets in each batch (more gas).
- No NFT approvals and no NFT operators from the account (only proven plain ERC-1155 operators, reset in the batch).
  The account moves its NFTs itself; NFT trades go through the owner's own wallet.
- No signatures of the account: no off-chain orders, permits or sign-in as the account. The owner's wallet signs.
- No marketplace orders from the account, no ERC-1820 / delegation registries, no v4 subscriptions, no flash-loan
  callbacks into the account, no plugins, no 4337 at the account (the owner may be a 4337 wallet).
- Tokenbound tools (locks, overrides, permissions) do not manage the account.
- A plain marketplace listing keeps the agent idle until the fill.

## 9. What is not covered (the residuals R-1…R-16)

- **R-1** A right made through a call the account cannot decode: an unknown wrapper, a selector not in the table, a
  spender the target computes, a forwarder, a target that lies about its own grant.
- **R-2** Bugs. There is no outside audit yet.
- **R-3** On the plain path, Promise 2 does not hold.
- **R-5** A token with a built-in allowance that no account action made.
- **R-6** Configuration rights that are not in the refused list (a fee recipient, a contract ownership, a pending
  owner of a two-step ownership transfer, a vote delegation, a rewards receiver or claimer). This includes contracts
  that the account owns or co-owns: a Safe that has the account as an owner accepts the account's own
  `execTransaction` with no signature, so a seller can add an owner or a module before the sale and keep the Safe.
- **R-7** Value inside other protocols moves under their rules (a liquidation, new debt, fees).
- **R-8** An NFT of another collection with its own wallet, inside the account. (The refused Tokenbound writes stop
  only a direct call; an inner AccountV3 can write the same storage through its own DELEGATECALL.)
- **R-9** Token admin powers (blacklist, pause, rebase).
- **R-10** An owner whose control changes without a transfer and that is not a registry clone (a Safe owned by
  another NFT's account, an NFT-gated EIP-7702 delegate).
- **R-11** An owner-push sale has no check; the buyer contract must check the account itself.
- **R-12** A collection with dishonest ERC-721 logic can name a real market or zone; list pinned collections only.
- **R-13** What conditions do not cover: value (only amounts), holdings that cannot be read or are not found,
  holdings left out to stay under the gas limit, the tolerance share, a value the seller can move inside a read.
- **R-14** Other accounts of the same token (another salt or implementation). Anyone can create them, the NFT owner
  controls them, and their actions do not show in the canonical account's `state()`. Count only the canonical account.
- **R-15** A cycle through another collection: a token of another collection in this token's account, and this token
  in that token's account. Both accounts can never act again. Only the owner who makes it loses.
- **R-16** A token sent to the empty address of its own clone (another salt or implementation): once the clone exists,
  the token owns itself, and it and its account lock for good. A burn that the sender makes; nobody can force it on a holder.

(R-4 is not used.)

**A checked path does not help against these.** The buyer's list is checked once, at the fill. A right on this list is
used later, so it reaches a buyer on a checked path in the same way as on a plain path.

## 10. The gas rule

The account holds back gas for its checks after each leg. So a call **needs more gas than it uses**. Size the limit
with `eth_estimateGas`; never as "gas used × k". On a 4663 fork (2026-10-29, before the refusals of K-84 to K-95
were added; measure your own build) the needed limit was
1.65–2.24 × the gas used:

| Call | Needed limit | Gas used |
|---|---|---|
| one-leg ETH send | 120,356 | 65,530 |
| one-leg ERC-20 transfer | 154,110 | 92,245 |
| approve → sell → reset | 403,473 | 179,980 |
| `readyToSell` + a journal entry | 179,674 | 108,694 |

A limit that is too low reverts on chain after a passing simulation (`GasReserve`, `ReadGas`).

## 11. FAQ

**Is ERC-6551P a standard?** No. It is a draft extension of ERC-6551, and the name is unofficial. It has no ERC number
and no EIPs pull request. The discussion link is in the draft's header (`discussions-to`).

**Is it audited?** No. It has had several AI-assisted and tool-assisted reviews, which are not an audit (`AUDIT.md`
lists each one and what no review has read). An outside audit is planned, and it will not be complete before the
first deployment.

**Does a buyer on OpenSea get Promise 2?** Only if the fill goes through `checkedFill` (or the zone). A direct fill of a
plain listing gets Promise 1 only.

**Why can the agent not sign?** A signature can move value through another contract with no change of `state()`. With
no signatures, every movement of value is an `execute`, and every `execute` changes `state()`. ERC-6551 allows an
account to "invalidate the holder as a signer".

**Why can the account not approve an NFT?** An approved address can make further rights during the batch (per-token
approvals, rental users, subscriptions) that no read finds. Refusing is simpler and cheaper than modeling them.

**What happens on a chain fork with a new chain id?** The account answers no owner there (it is bound to the old chain
id), so nobody can make it call on the fork; every non-owner transfer reverts; old orders fail their EIP-712 domain.
The owner's own transfer still works (`test_K78_aChainIdChangeFreezesTheAccountAndKillsOldOrders`).

**Where do the ideas come from?** From ERC-6551, its forum threads, the Tokenbound code and the public reports
that `problem.md` lists.

**Can another collection use it?** Yes: inherit `ERC6551PCollection`, pass the shared account implementation, market
and zone (`integration.md`). The example is `examples/ExampleERC6551PCollection.sol`.

**What if the owner of the NFT is an ERC-6551 account?** It cannot make the token ready and cannot sell it through
the rule. It moves the NFT to a plain wallet first, then sells.
