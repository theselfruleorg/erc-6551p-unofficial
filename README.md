# ERC-6551P (unofficial): transfer-safe token bound accounts

An NFT that owns a wallet, and that you can sell safely: the seller cannot keep a key to the wallet, and on a checked
sale the buyer gets exactly what they checked, or the sale does not happen. There is no lock on the wallet.

This repository holds the draft proposal, the contracts, the tests and the docs. Any ERC-721 collection can use it.

> **Status: a draft, experimental, NOT audited, NOT deployed.**
> "ERC-6551P" is an unofficial working name. It is not an ERC number, not an accepted standard and not an official version of
> ERC-6551. Nobody from the EIP editors or the ERC-6551 authors has reviewed or endorsed it. No outside firm has audited
> this code ([`AUDIT.md`](AUDIT.md)). Value held in a deployment of this code can be lost.

**Contents:** [In plain words](#in-plain-words) · [The problem](#the-problem) · [The design](#the-design) ·
[The two promises](#the-two-promises-and-only-these-two) · [What is not covered](#what-is-not-covered) ·
[ERC-6551](#how-it-relates-to-erc-6551) · [Use it](#use-it) · [Build and test](#build-and-test) ·
[Files](#what-is-here) · [Audit](#audit-status) · [Plan](#plan)

## In plain words

[ERC-6551](https://eips.ethereum.org/EIPS/eip-6551) gives an NFT its own wallet. Whoever owns the NFT controls the
wallet. So when you buy the NFT, you also buy what is in its wallet: tokens, coins, other NFTs.

Think of the NFT as the deed of a house, and of the wallet as a safe inside the house. With a normal ERC-6551 wallet,
two bad things can happen when the house is sold:

- **A spare key.** The seller gives a key of the safe to a friend before the sale. After the sale, the friend opens
  the safe and empties it. (On chain, the "key" is an approval or a signature that the wallet gave.)
- **The empty safe.** You see 1 ETH in the safe and you pay. A moment before your purchase goes through, the seller
  takes the 1 ETH out. You get an empty safe.

ERC-6551P answers both:

- **No spare keys.** The wallet refuses to give out a key that it cannot take back. A key that it gives for one
  action must come back before that action ends. When the deed changes hands, only the new owner can open the safe.
  This holds on every sale, on any marketplace.
- **A checklist at the closing.** On a *checked sale*, you write a checklist before you pay: for example "at least
  1 ETH" and "this NFT". The NFT moves, then your checklist is checked on the wallet, in the same step. If one item
  is missing, the whole sale is cancelled, and you keep your money.

### Two ways to buy

| How you buy | What you get |
|---|---|
| **A checked sale**: through the ERC-6551P market, the ERC-6551P zone on Seaport, or the market's `checkedFill` of any Seaport listing | The seller keeps no key, **and** your checklist is checked. If the wallet was emptied, the sale is cancelled. |
| **A plain sale**: a normal "Buy now" on a marketplace | The seller keeps no key. **But nothing is checked for you.** The seller can empty the wallet before your purchase goes through. |

**Buy only with a checked sale if the wallet holds value that you pay for.** A plain sale is safe only for the NFT
itself.

### What the seller cannot take back, and what to check yourself

**Fully covered, on every sale:** what sits in the wallet itself. That is ETH, tokens and NFTs. An approval, a permit or
an old signed order of the seller does not work after the sale. The wallet signs nothing, and only the new owner can make
it act. One exception: a token whose own code lets someone else move or freeze it (a built-in spender, an admin
blacklist). That is a property of the token, not of the wallet (R-5, R-9).

**Check yourself:** positions in other apps. The wallet can also use other apps, for example a staking or a lending
app. Each app keeps its own records, and some apps let a user write "send my rewards to X" or "X may act for me". The
wallet knows the common records of this kind and refuses them or checks them. But anyone can deploy a new app with a
new kind of record, so no wallet can know them all. (In the picture of the house: all the locks are changed, but the
seller could have set up a mail redirect at an office that nobody knows.)

So, as a buyer: the seller cannot take back anything that sits in the wallet. If the wallet holds positions in other
apps, check those apps too, or count those positions as worth nothing.

### What a checklist cannot see

- **Value.** A checklist checks amounts, not prices. "100 tokens" can be 100 tokens that are worth nothing.
- **Things that it does not list.** It checks only the items on the list.
- **Rights that are used later.** The checklist is checked once, at the sale. Some rights fall outside both promises
  (see [What is not covered](#what-is-not-covered)), and a checklist does not stop them.

## The problem

ERC-6551 leaves the sale out of its scope: "Preventing fraud is outside the scope of this proposal." When an NFT with
an account is sold, these things can go wrong:

1. **The last-second drain.** The seller empties the account just before the buyer's fill.
2. **Leftover rights.** An allowance or operator given before the sale still works after it, and it does not change
   `state()`.
3. **Signatures.** A permit or an off-chain order signed for the account moves value through another contract, with no
   change of `state()`.
4. **The lock.** A lock freezes the account, so an agent that lives in it stops. It also does not stop transfers that use
   allowances, and it allows griefing.
5. **An owner change inside a batch.** Later legs of the batch run with an authority that the new owner holds.
6. **Ownership cycles and nesting.** A token inside its own account locks the assets for good.

These are known design problems, with public sources in [`docs/problem.md`](docs/problem.md). We found no public report of
a buyer who lost value in this way.

## The design

ERC-6551P has three parts. There is no lock, freeze or escrow.

**1. The account.** It is an ERC-6551 account with strict rules:

- Only the NFT's current owner can make it call, and only with CALL.
- The owner is checked again after every leg of a batch.
- `state()` changes on every batch and never repeats a value.
- No grant that the account can read back outlives the batch that made it.
- It gives no NFT approval, no NFT operator and no signature.
- It refuses a fixed list of rights that it cannot read back (the draft, §1.10).
- It has no modules, permissions, overrides, guardian, upgrade path or ERC-4337 entry point.

**2. The collection rule.** It is on the ERC-721 itself. A transfer by anyone other than the owner needs all of these:

- the account is not inside a batch;
- the seller is not an ERC-6551 account;
- either readiness from an EARLIER transaction (the account has not acted since), or a one-use ticket of a named market
  or zone, bound to (from, to, account state).

**3. The checked sale.** The buyer writes conditions on the account: balances, positions, a state value. They are read
after the NFT transfer, in the same transaction, and a failed condition reverts the fill. The paths are the market's `buy`
and `accept`, `checkedFill` of a Seaport 1.6 listing, and a Seaport 1.6 zone order.

## The two promises, and only these two

- **The seller keeps no right (G1).** After the sale, the seller, and anyone the seller named, holds no right over
  what the account holds, on the rights that the account models or refuses. It holds on every sale path, also on a
  plain marketplace fill.
- **You get what you checked (G2).** The fill happens only if every condition that the buyer wrote holds after the
  transfer. It holds on the checked paths only, never on a plain marketplace fill.

Both promises speak of the token's canonical account (the registry clone of the collection's implementation, salt 0).

## What is not covered

The account can call any contract. Any contract can store a right for the account in its own storage, behind any
function. So **no list of refused or read-back rights can be complete**: a right that the account cannot read and does
not list is not covered. Full coverage needs an allow-list (the account calls only reviewed contracts), and that would
make the account useless as a general wallet. ERC-6551P covers the known kinds and names the rest.

What IS closed for every contract: any right that needs a signature of the account, because the account signs nothing.

The named limits are the residuals R-1 to R-16, in the draft's Security Considerations. The main ones:

- **R-1** a right made through a call that the account cannot decode;
- **R-3** a plain fill gives no checklist;
- **R-6** configuration rights that are not refused, for example the owner of a Safe or of another contract that the
  account owns, a fee recipient or a rewards receiver;
- **R-8** NFTs of other collections with their own wallets, inside the account;
- **R-13** what a checklist cannot see (value, items that it does not list or cannot read);
- **R-14** other accounts of the same token; only the canonical account is covered.

These rights are used after the sale, so a checked sale does not stop them either. A front end that knows such a
right can add a condition on its getter.

## How it relates to ERC-6551

**What it keeps:** the canonical registry, the ERC-1167 clone with the standard footer, the permanent binding of the
account to the token, `token()`, `state()`, and the `IERC6551Account` and `IERC6551Executable` interfaces with the same ABI
shapes. It asks for no change to ERC-6551 or to the registry.

**Where it does NOT follow ERC-6551.** We do not claim full conformance:

| ERC-6551 | This account | Reason |
|---|---|---|
| "MUST implement ERC-1271 signature validation" | `isValidSignature` always rejects, and the account does not advertise ERC-1271 | a signature can move value with no change of `state()` |
| The holder is a valid signer by default; an implementation MAY invalidate the holder | `isValidSigner` never accepts an address | the owner acts by calling `execute` |
| `IERC6551Executable` operations 0 to 3 | only CALL; DELEGATECALL, CREATE and CREATE2 revert | code from outside could skip the checks |

**What this costs:**

- No permits, off-chain orders or sign-in from the account.
- Tokenbound tools (locks, overrides, permissions, ERC-4337) do not manage it.
- A plain marketplace fill of a token that is not ready reverts.
- An existing collection cannot adopt it without the rule in its transfer path. Plain ERC-6551 works with any existing NFT.
- It needs legacy (non-EOF) clones.
- An account call needs more gas than it uses. Size each call with `eth_estimateGas`, never with "gas used × k".
- The approve probe fails closed on WETH9 on Ethereum and Base. A deployment on those chains must decide about this.

## Use it

> **Warning:** there is no outside audit yet. Do not use this code to hold value that you cannot lose.

**1. Deploy the shared contracts once per chain.** Any number of collections can share them:

| Order | Contract | Constructor |
|---|---|---|
| 1 | `JournalLog` | none |
| 2 | `ERC6551PAccount` (the ERC-6551P account implementation) | `(journal)` |
| 3 | `ERC6551PMarket` | `(seaport16, accountImpl)` |
| 4 | `ERC6551PZone` | `(seaport16, accountImpl)` |

Seaport 1.6 is `0x0000000000000068F116a894984e2DB1123eB395`. Use CREATE2 with the same arguments, and each contract gets
the same address on every chain. After the deploy, check that `market.ACCOUNT_IMPL()`, `zone.ACCOUNT_IMPL()` and
`collection.ACCOUNT_IMPL()` are equal ([`docs/integration.md`](docs/integration.md) §1).

**2. Write your collection.** Inherit `ERC6551PCollection`, mint with `_mintWithAccount`, and answer the interface id:

```solidity
contract MyCollection is ERC6551PCollection {
    constructor(address accountImpl, address market, address zone)
        ERC721("My Collection", "MINE")
        ERC6551PCollection(accountImpl, market, zone)
    {}

    function mint(address to, uint256 id) external /* your access rule */ returns (address account) {
        account = _mintWithAccount(to, id); // the token's account is created in the same call
    }

    function supportsInterface(bytes4 id) public view override returns (bool) {
        return id == type(IERC6551PCollection).interfaceId || super.supportsInterface(id);
    }
}
```

The full example is [`examples/ExampleERC6551PCollection.sol`](examples/ExampleERC6551PCollection.sol). Do not add a
transfer path that skips the rule (an internal transfer, an escrow, a rescue or staking function).

**3. Sell.** Sell through the market (`buy`, `accept`, `checkedFill`) or a zone order. A plain marketplace listing fills
only while the token is ready (`readyToSell` as the last leg of an account batch, in an earlier transaction). Before a new
readiness, cancel the older plain listings: a new readiness brings them back.

**4. Size the gas.** Size every account call with `eth_estimateGas`: the account holds back gas for its checks.

Compiler: Solidity 0.8.24, optimizer 200 runs, `evm_version = cancun` (EIP-1153 transient storage is required).

Nothing in these contracts is specific to one collection: the account serves any token through its ERC-6551 footer,
and the market and the zone serve any collection that names them.

## Build and test

```bash
git clone --recurse-submodules <this repository>
forge build
forge test
```

Dependencies: OpenZeppelin Contracts v5.1.0 and forge-std v1.11.0, as git submodules.

The 114 tests here use mocks and the real ERC-6551 registry bytecode, offline. The fork tests, the real Seaport 1.6 gate
and the market and zone suites run against the first deployment's collection, and they are not in this repository yet
([`AUDIT.md`](AUDIT.md) §6).

## What is here

| Path | What it is |
|---|---|
| [`docs/erc-6551p.md`](docs/erc-6551p.md) | the proposal in EIP format: Specification, Rationale, Backwards Compatibility, Test Cases, Security Considerations |
| [`docs/problem.md`](docs/problem.md) | the known issues at a sale, each with its source and the answer |
| [`docs/guide.md`](docs/guide.md) | the full guide, from simple to exact |
| [`docs/integration.md`](docs/integration.md) | how a collection, a marketplace, a wallet or an agent framework integrates |
| [`docs/reference.md`](docs/reference.md) | every function, event, error and ERC-165 id, generated from the compiler |
| [`AUDIT.md`](AUDIT.md) | every review, its findings and fixes, and what no review has read |
| [`SECURITY.md`](SECURITY.md) | how to report a vulnerability |
| `src/account/ERC6551PAccount.sol` | the account |
| `src/kit/ERC6551PCollection.sol`, `src/kit/AccountedERC721.sol` | the collection rule: readiness, tickets, `transferCount`, ERC-5646, no nesting |
| `src/sale/Conditions.sol`, `ERC6551PMarket.sol`, `ERC6551PZone.sol` | the checked sale |
| `src/interfaces/` | `IERC6551PCollection` (`0x6b7481e3`) and the account's `inBatch()` (`0x92ad233c`) |
| `src/kit/JournalLog.sol` | the journal contract that the account allows after a `readyToSell` leg |
| `examples/ExampleERC6551PCollection.sol` | the smallest collection that uses the kit |
| `test/` | the test suites, mocks and fixtures |

## Audit status

**No outside audit yet.** The code had AI-assisted reviews and static and fuzz tools; these are not an audit.
[`AUDIT.md`](AUDIT.md) lists each review, each finding and its fix, the items that stay open, and the changes that no
review has read yet.

## Disclosure

The authors plan the first deployment of this code for their own NFT collection, POLYROB, on Robinhood Chain (4663),
and they have a commercial interest in it. That deployment uses this code with no change except names: the contract names, the EIP-712
domain name of the market, the zone's metadata name and the keys of its internal storage slots. Its own collection and sale contracts are not in this repository.

An outside audit is planned, and it will not be complete before that first deployment. So that deployment is experimental.

## Plan

1. Publish the draft and this repository, and open the discussion.
2. Collect technical feedback, and change the draft where it is wrong.
3. Run the rehearsal on Robinhood Chain testnet (46630), and publish the result.
4. Outside audit: publish the report and the status of each finding.
5. First deployment on Robinhood Chain (4663): publish the addresses and the code hashes.
6. Open a pull request on `ethereum/ERCs` to ask for a number.

## Security

Read [`SECURITY.md`](SECURITY.md). Do not report a vulnerability in a public issue.

## License

The code is MIT ([`LICENSE`](LICENSE)). The proposal text is CC0 ([`LICENSE.md`](LICENSE.md)).
