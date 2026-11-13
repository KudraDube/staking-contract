# StakingRewards

A staking contract where users deposit a token and earn rewards over time, built to understand how DeFi protocols pay thousands of users without looping over them.

Think of a shared electricity meter for a block of flats. The building pays a fixed amount per second to the whole block. Instead of splitting the bill between tenants every second the contract keeps ONE running number: reward earned per staked token so far. Each tenant only remembers the meter reading from their last settlement. Earnings = stake x (meter now - meter at last settlement).

## Why I built it

This is the pattern behind most reward-paying DeFi contracts (Synthetix-style staking). The hard part is not the code length. It is the discipline: the accumulator must be updated BEFORE any balance changes or the maths silently pays the wrong people. I wanted to understand that well enough to rewrite the core from memory with small numbers and to explain every line to an interviewer.

## Status

| Item | State |
|---|---|
| Contract | Complete, patched with the Contracts Pack fixes |
| Tests | 45 passing (unit, accumulator maths, reentrancy, fuzz, invariant) |
| Audit | None. This is a learning project, **do not deploy with real funds** |

## How it works

| Piece | Job |
|---|---|
| `rewardPerToken()` | The meter. Grows by rate x elapsed x 1e18 / totalSupply and stands still when nobody is staked |
| `lastTimeRewardApplicable()` | Stops accrual at `periodFinish` |
| `earned(account)` | Stake x (meter now - user's last reading) + already banked rewards |
| `updateReward` modifier | Runs BEFORE the function body so the old balance is used for the old period |
| `notifyRewardAmount` | Owner starts a reward period. Unpaid leftovers roll into the new rate. |

The tiny numbers I check my understanding against: rate 10 per second. Alice stakes 100 at time 0 and Bob stakes 100 at time 10. At time 20 Alice has earned 150 and Bob 50 (total 200 = 20 seconds x 10). A test asserts exactly these figures.

## What I patched and why

The original `notifyRewardAmount` never checked that the contract could pay what it promised. If the owner announced a rate the contract could not fund then the last people to claim would find their transactions reverting.

- `duration > 0`: a zero duration caused a raw divide-by-zero panic. Now it fails with a clear message.
- `rewardRate > 0`: a tiny reward over a long duration rounds the rate down to zero and the period silently pays nothing.
- **Solvency check:** `rewardRate x duration` must not exceed the reward tokens the contract actually holds. When the staking and reward token are the same token the stakers' deposits are subtracted first because they are not reward money.
- **Events** for stake, withdraw, claim and each new reward period, so off-chain tools can follow the contract.

Nine of the tests fail against the unpatched version and pass against the patched one.

## Design decisions

- **One global accumulator** instead of a loop over users, so gas cost does not grow with the number of stakers.
- **1e18 scaling** so small rewards do not round to zero.
- **`nonReentrant` on every function that moves tokens** and balances updated before transfers.
- **The owner pre-funds the contract** with reward tokens and then calls `notifyRewardAmount`. The contract checks the funding rather than trusting the owner.

## Known limitations

- **The solvency check looks at the contract's reward balance.** It does not subtract rewards that users have already earned but not yet claimed. A stricter version would track total rewards owed.
- **Rewards earned while nobody is staked are stranded.** The accumulator stands still on an empty pool so that time's rewards stay in the contract with no way to recover them. A test documents this.
- **Fee-on-transfer staking tokens are not supported.** The deposit is credited at the nominal amount (the same issue I patched in my escrow contract).
- **No rescue function** for tokens sent to the contract by mistake.
- **`exit()` reverts if nothing is staked** because `withdraw(0)` is rejected.
- **The owner is a single address.** It can start periods but cannot take staked funds. Renouncing ownership would stop future reward periods.
- **Reward rate rounding** leaves a few wei of dust per period.

## Tests

`test/StakingRewards.t.sol`, 45 tests:

- every function: happy path, every `require`, events and access control
- the pack's Alice and Bob numbers asserted exactly
- accrual edge cases: before funding, empty pool, late joiner, full withdrawal, after `periodFinish`
- mid-period top-up where leftovers carry into the new rate and total payout equals total funding
- reentrancy tests with hostile tokens on both the staking and the reward side
- fuzz tests: rewards never exceed funding and larger stakes earn more over the same time
- 4 invariants after random stakes, withdrawals, claims and time jumps: staked tokens held equal `totalSupply`, `totalSupply` equals the sum of stakes, and tokens are conserved

## Run it

```bash
forge install OpenZeppelin/openzeppelin-contracts foundry-rs/forge-std
forge test
```

## What I practised

- the accumulator pattern and why the modifier must run before the balance changes
- running the maths by hand with tiny numbers and then proving it with exact test assertions
- time-based testing with `skip` and `vm.warp`
- reading a security finding in the Contracts Pack and turning it into failing tests and a fix
- invariant testing with a handler that jumps through time
- being honest about limits: documenting what the contract does NOT protect against

## Where this is going

I am a WeThinkCode blockchain graduate building towards a junior Solidity or Web3 role. This repository is one of a set (SimpleDEX, EthVault, MultiSigWallet, P2PEscrow, StakingRewards) where each contract comes with tests I can explain line by line.
