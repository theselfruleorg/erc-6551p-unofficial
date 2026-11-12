# ERC-6551P — integration

ERC-6551P is a **draft** extension of ERC-6551, not an accepted standard;
the reference implementation is **not audited, not deployed**. Nothing on this page is live: no
address of the account implementation, the market or the zone exists on any chain yet. Until a deployment is
announced, every address below is a placeholder.

Three audiences: a **collection** that adopts the kit (§1), a **marketplace or wallet** (§2), an **agent framework**
(§3). The exact rules: `erc-6551p.md`; every selector, event and error: `reference.md` (generated from the compiler).

---

## 1. A new collection adopts the kit

### 1.1 What you share and what you deploy

| Piece | Who deploys it | How many |
|---|---|---|
| The ERC-6551 registry `0x000000006551c19487814612e58FE06813775758` | already on every chain that has it (canonical, permissionless) | one |
| `JournalLog` (the journal; the only target that legs after `readyToSell` may call) | the first deployment (CREATE2) | one, shared |
| `ERC6551PAccount(JOURNAL)` — the ERC-6551P account implementation | the first deployment (CREATE2) | one, shared |
| `ERC6551PMarket(SEAPORT, ACCOUNT_IMPL)` | the first deployment (CREATE2) | one, shared |
| `ERC6551PZone(SEAPORT, ACCOUNT_IMPL)` | the first deployment (CREATE2) | one, shared |
| **your collection** `is ERC6551PCollection` | you | one per collection |

The market and the zone have **no collection immutable**: they serve every collection that names them
(`c.MARKET() == market`, `c.ZONE() == zone`, checked on every call). They compute every account with their own
`ACCOUNT_IMPL`. So a collection that uses the shared market MUST use the shared account implementation; with another
implementation every checked fill reverts `BadAccount` (`test_K71_aCollectionWithAnotherAccountImplCannotUseTheMarket`).

### 1.2 The code

```solidity
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC6551PCollection} from "./kit/ERC6551PCollection.sol";
import {IERC6551PCollection} from "./interfaces/IERC6551P.sol";

contract MyCollection is ERC6551PCollection {
    constructor(address accountImpl, address market, address zone)
        ERC721("My", "MY")
        ERC6551PCollection(accountImpl, market, zone)
    {
        // check your arguments: the kit does not (the example reverts on a code-less impl or a zero address)
    }

    function mint(address to, uint256 id) external /* your access rule */ {
        _mintWithAccount(to, id); // creates the account at the registry, salt 0, then mints
    }

    function supportsInterface(bytes4 i) public view override returns (bool) {
        return i == type(IERC6551PCollection).interfaceId || super.supportsInterface(i);
    }
}
```

The whole minimal example: `examples/ExampleERC6551PCollection.sol` (35 lines); its tests:
`test/ERC6551PExample.t.sol` and `test/ERC6551PCorner.t.sol`.

Rules for the adopter:

- **Mint only with `_mintWithAccount`.** The account must exist before the token: the no-nesting check is exact only
  for ids whose account has code (`AccountedERC721`, its `@dev`).
- **Do not override `_update` to skip the rule.** If you override it, call `super._update` and keep its result.
- **No internal transfer of a holder's token.** The rule runs only for a transfer with an authorization (`auth != 0`).
  Do not add an escrow, rescue or staking path that moves a holder's token with `_transfer`: it skips the rule.
- **Answer the ERC-165 id `0x6b7481e3`** (`IERC6551PCollection`); the kit does not answer it for you. The kit answers
  ERC-5646 (`0xf5112315`) and ERC-4906 (`0x49064906`).
- **The relative condition kinds** (`MINT_POSITION`, `IDENTITY`) read `positionOf(uint256)`, `hasIdentity(uint256)` and
  `agentIdOf(uint256)` on your collection. If you do not have them, these kinds fail (never a false pass). If you add
  them, they MUST be honest: a buyer relies on them. Do not add a `fallback` that returns 32 bytes: it would answer
  those reads.
- **Royalty.** The market pays ERC-2981 `royaltyInfo` if your collection answers it, capped by the `maxRoyalty` that
  the seller or the buyer signed. No ERC-2981: no royalty.
- **No setter.** `ACCOUNT_IMPL`, `MARKET` and `ZONE` are immutables. Do not add a way to change them: a ticket opener
  is a full sale permission.
- `_onReadyChanged(id, ready)` is a hook for your metadata events (ERC-7496 / ERC-4906); it must not revert.

### 1.3 The deploy order

1. (Once, shared) `JournalLog`, then `ERC6551PAccount(JOURNAL)`, `ERC6551PMarket(SEAPORT, ACCOUNT_IMPL)`,
   `ERC6551PZone(SEAPORT, ACCOUNT_IMPL)`, each by CREATE2 with chain-independent arguments (the same salt gives the
   same addresses on every chain).
2. Your collection, with the three addresses as constructor arguments.
3. Check after the deploy: `market.ACCOUNT_IMPL() == zone.ACCOUNT_IMPL() == collection.ACCOUNT_IMPL()`;
   `collection.MARKET()`, `collection.ZONE()`; `market.SEAPORT() == zone.SEAPORT()` = Seaport 1.6
   `0x0000000000000068F116a894984e2DB1123eB395`; the runtime sha256 of each piece; the clone of token #1
   (`accountOf(1).code.length == 173`, `token() == (chainid, collection, 1)`). A deploy script SHOULD make these checks and stop on a mismatch.

### 1.4 What to test

Run the ERC-6551P suites against your collection (copy `ERC6551PExample.t.sol` and `ERC6551PCorner.t.sol` and replace
the example). At least: an operator transfer needs readiness; readiness from the same transaction does not count; any
account batch ends readiness; no sale inside the account's batch; no token into an account of the collection (any
implementation); only the market or the zone opens a ticket; a market `buy` checks the buyer's conditions; a drain
before the fill reverts; a listing dies when the token moves; the ERC-165 ids; your own mint and any `_update`
override. The draft's Test Cases section lists the tests a second implementation should pass.

## 2. A marketplace or a wallet

### 2.1 Read

| Read | Use |
|---|---|
| `supportsInterface(0x6b7481e3)` on the collection | it is an ERC-6551P collection |
| `accountOf(id)`, or the registry's `account(impl, 0, chainid, collection, id)` | the token's account; compute it yourself with the pinned implementation |
| `saleReadyOf(id)` | a plain listing can fill only while this is true |
| `transferCount(id)` | a market or zone listing signs it; a different value means the listing is dead |
| `getStateFingerprint(id)` (ERC-5646) | `keccak256(owner, transferCount, account.state())`; changes on any transfer and any account batch, not on a deposit |
| `account.state()`, `account.inBatch()` | the account's state value; `inBatch()` is true only inside a batch |
| event `SaleReady(id, owner, state)` | readiness starts. Readiness ends with no event of its own (a `Transfer`, or an account batch that changes `state()`): read `saleReadyOf(id)` again after either |

### 2.2 Show

- Show a plain listing as fillable only while `saleReadyOf(id)` is true. It ends with every account action. A new
  `readyToSell` makes the owner's older plain listings fillable again: a Sell flow cancels the older Seaport orders it
  knows (Seaport `cancel`) before it makes the token ready again. `incrementCounter` also works, but it ends every
  Seaport order of the wallet, so it must be the seller's explicit choice.
- Show only the **canonical** account (salt 0, the collection's implementation). Other accounts of the same token are
  outside both promises (R-14).
- Show what the account holds from a fresh read, and label holdings whose value you do not know. A seller can fill the
  account with a worthless token, or with a token that answers a different balance to you than to the market.

### 2.3 Fill

- **Check the implementation first**: `collection.accountImplementation() == market.ACCOUNT_IMPL()`. The market reads
  the conditions on the clone of ITS implementation; for a collection with another implementation that clone is not
  the account the sale rule watches.
- **Fill every listing through `checkedFill`.** It takes any Seaport 1.6 order whose offer is exactly the one sold NFT
  (order types 0–3, no criteria, one currency, nothing paid to the account, the offerer not an ERC-6551 account). The
  market is Seaport's recipient, then sends the NFT to the caller and checks the buyer's conditions. Arguments:
  `checkedFill(order, resolvers = [], fulfillerConduitKey, Fill(collection, soldId, currency, maxPayment),
  buyerConditions)`; ETH: `msg.value == maxPayment`; ERC-20: approve the market for `maxPayment`. The change comes back.
- **Make offers through the market** (`Offer`, signed by the buyer, conditions bound by `conditionsHash`); the seller
  fills with `accept`. A plain Seaport offer gives no buyer check.
- **Zone orders**: fill with `fulfillAdvancedOrder` directly (recipient = the fulfiller) or with `checkedFill`.
  `matchAdvancedOrders`, `fulfillAvailable*` with another recipient, aggregator routers that call Seaport for a user,
  and basic orders do not work with the zone (they revert): its ticket binds the fulfiller.

### 2.4 Build the buyer's conditions

1. Read every holding of the account: ETH; every ERC-20, ERC-721, ERC-1155, ERC-6909 and v4 position you can find
   (from logs and known lists). Keep the fill under the gas limit: cap the conditions per fill, put the known holdings
   first, and label the holdings left out (R-13); anyone can send dust tokens to any account.
2. Add one condition per holding: `ERC20 ≥ b − floor(b × t)`, `ERC721` (owned, not approved), `ERC1155` / `ERC6909 ≥ …`,
   `V4POSITION ≥` the liquidity shown with the pool hook named in `data`; and `ETH ≥ …`. `t` is the buyer's
   tolerance: 0 for offers and idle listings; at most 0.5 % for an active agent's listing. With `b ≥ 1` keep `min ≥ 1`.
3. On a collection that answers `positionOf` / `hasIdentity`, add `MINT_POSITION` (when `positionOf(id) ≠ 0`) and
   `IDENTITY` (when `hasIdentity(id)`).
4. **Simulate** the fill (`eth_call`) from the buyer's own address. `ConditionFailed(i)` names condition `i`: drop that
   holding, label it "cannot be checked, count it as worth 0", and simulate again.
5. Do not count money that the fill itself pays as value of the account. The market and the zone refuse a
   consideration item paid to the account, but a seller can pay a forwarder that sends the buyer's money there.

### 2.5 What you do not get

A direct fill of a plain listing (not through `checkedFill`) and a plain offer that the seller fills give Promise 1
only (R-3). The value of a holding is never checked (R-13). A collection with dishonest ERC-721 logic can name the real
market (R-12): list pinned collections only.

## 3. An agent framework

The agent controls the account only by **owning the NFT** on its own address. It calls the account directly:

- `execute(to, value, data, 0)` returns `abi.encode(bytes result)` (the AccountV3 shape);
  `executeBatch((to, value, data, 0)[])` returns `bytes[]`.
- **Approve → spend → reset in one batch**: `[approve(S, X), spend, approve(S, 0)]`. A grant higher at the end than at
  the start reverts the batch (`StandingGrant`).
- **Do not** approve an NFT, make an NFT operator (except a plain ERC-1155, reset in the batch), call any Seaport, CoW
  `setPreSignature`, Safe `approveHash`, ERC-1820, delegate.xyz, v4 `subscribe`, the Tokenbound `setPermissions` /
  `setOverrides` / `lock`, the ERC-8004 `setAgentWallet` / `unsetAgentWallet`, or rely on a signature of the account:
  these revert (`Refused`) or fail. The full refused list is in the draft §1.10. Use the agent's own wallet for NFT trades and off-chain orders, then move the asset
  into the account with a plain transfer.
- **Gas**: size every account call with `eth_estimateGas` (or a search on success). Never "gas used × k": the account
  holds back gas for its post-leg checks, and a call needed 1.65–2.24 × the gas it used (measured on a 4663 fork on 2026-10-29, before the later refusals; measure
  your own build). A low
  limit reverts on chain after a passing simulation (`GasReserve`, `ReadGas`).
- **Selling**: `readyToSell(id)` on the collection as the LAST leg of a batch (only `JournalLog.log(bytes)` entries with
  value 0 may follow). The next batch of the agent ends readiness; to keep working while listed, list through the
  market or the zone instead.
- **The owner of the NFT must not be an ERC-6551 account** if the token is to be sold: move it to a plain wallet first.
- Errors and what they mean: `reference.md` (all errors, from the compiler).
