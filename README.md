# FoundationFunder

A Solidity smart contract for rate-limited ERC20 token disbursement. A governance address (`gov`) sets per-token quarterly budgets that stream linearly over time. A `beneficiary` can pull tokens up to the accrued budget, and optionally authorize `delegates` with their own independent streaming sub-limits.

## How It Works

### Roles

- **Gov** — Sets quarterly token budgets and can transfer its own role or the beneficiary role.
- **Beneficiary** — Pulls tokens from gov's balance within the quarterly budget. Can authorize delegates and transfer its own role.
- **Delegates** — Pull tokens on behalf of the beneficiary, subject to both the quarterly budget *and* their own per-delegate streaming limit.

### Streaming Token Buckets

Budgets are not unlocked all at once. They accrue linearly over time using a token bucket model:

- **Quarterly bucket** — Gov sets a `quarterlyLimit` per token. The available balance streams from 0 to `quarterlyLimit` over 90 days. After a pull, the bucket continues accruing from its reduced level. The available balance is capped at `quarterlyLimit` (no accumulation beyond one quarter).

- **Delegate bucket** — The beneficiary configures each delegate with a `limitAmount` and `interval`. The delegate's available balance streams from 0 to `limitAmount` over `interval` seconds, functioning identically to the quarterly bucket but on a custom timescale.

When a delegate pulls tokens, **both** buckets are checked and consumed. The pull succeeds only if the requested amount is within both the quarterly budget and the delegate's own limit.

### Pull Mechanism

Tokens are transferred directly from `gov`'s wallet via `transferFrom` — the contract never holds funds. Gov must approve the contract to spend its tokens.

Every pull requires a `reason` string that is emitted in the `FundsPulled` event for transparency and auditability.

### Mid-Stream Configuration Changes

Quarterly limits and delegate configs can be updated at any time. When changed, the contract first accrues any tokens earned under the old parameters, then applies the new config. If the new limit is lower than the current accrued balance, the balance is capped to the new limit.

## Building & Testing

Requires [Foundry](https://book.getfoundry.sh/).

```bash
forge build
forge test
```

## License

MIT
