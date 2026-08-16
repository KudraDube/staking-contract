# StakingRewards

A Solidity staking contract implementing the Synthetix-style fixed-rate reward
accumulator pattern. Users stake an ERC20 token and earn rewards (in the same
or a different ERC20) proportional to their share of the pool and the time
they've staked — without the contract ever looping over stakers to calculate
history.

Built with [Foundry](https://book.getfoundry.sh/) and [OpenZeppelin Contracts](https://www.openzeppelin.com/contracts).

## About

Written by Kudra Dube — blockchain developer with a legal background (LLB,
Wits), currently completing WeThinkCode's development programme. This project
was built to demonstrate a solid grasp of a widely-used DeFi primitive: the
reward-per-token accumulator pattern found in real production contracts.

[LinkedIn](https://linkedin.com/in/kudra-dube-a12706162) · [GitHub](https://github.com/KudraDube)

## How it works

The contract tracks a single global accumulator, `rewardPerTokenStored`, which
answers: "if you'd staked exactly 1 token since the contract began, how much
reward would that token have earned by now?" Each user's own claimable reward
is calculated as their balance times the difference between the current
accumulator value and a personal snapshot taken the last time their balance
changed. This lets stakers join and leave at arbitrary, unsynchronized times
while still being paid a fair, gas-cheap share.

Core functions:

| Function | Purpose |
|---|---|
| `stake(uint256 amount)` | Deposit staking tokens |
| `withdraw(uint256 amount)` | Withdraw staked tokens |
| `getReward()` | Claim accrued rewards |
| `exit()` | Withdraw full balance and claim rewards in one call |
| `notifyRewardAmount(uint256 reward, uint256 duration)` | Owner-only: fund and start/extend a reward period |
| `earned(address account)` | View: rewards currently owed to an account |
| `rewardPerToken()` | View: current value of the global accumulator |

## Project structure

```
├── src/
│   └── StakingRewards.sol
├── test/
│   └── StakingRewards.t.sol
├── script/
│   └── DeployStakingRewards.s.sol
└── foundry.toml
```

## Setup

```bash
git clone https://github.com/KudraDube/staking-contract.git
cd staking-contract
forge install
forge build
```

## Testing

```bash
forge test -vvv
```

Tests cover staggered stakers (using `vm.warp` to simulate users staking at
different times) to verify the accumulator distributes rewards fairly across
overlapping and non-overlapping staking periods.

## Deployment

Deployed and verified on BSC Testnet, then redeployed unchanged to BSC
Mainnet.

```bash
forge script script/DeployStakingRewards.s.sol --rpc-url $BSC_TESTNET_RPC --broadcast --verify
```

Set the following in a `.env` file (not committed):

```
BSC_TESTNET_RPC=
BSC_MAINNET_RPC=
PRIVATE_KEY=
BSCSCAN_API_KEY=
```

### Deployed addresses

| Network | Contract | Address |
|---|---|---|
| BSC Testnet | StakingRewards | `TBD` |
| BSC Mainnet | StakingRewards | [`0x71f4f7fa4004f3e7d04968ea8967cd0a95bab0c4`](https://bscscan.com/address/0x71f4f7fa4004f3e7d04968ea8967cd0a95bab0c4) |
| BSC Mainnet | MockERC20 (staking token) | [`0xfbb331829cc7d67db805c4d8ba4d95b21071e662`](https://bscscan.com/address/0xfbb331829cc7d67db805c4d8ba4d95b21071e662) |
| BSC Mainnet | MockERC20 (rewards token) | [`0x8cef581fa5af147fb56070ea8cc976993fd56abf`](https://bscscan.com/address/0x8cef581fa5af147fb56070ea8cc976993fd56abf) |

> Note: this is a demo deployment using mock ERC20 tokens for both staking
> and rewards, intended to demonstrate a real mainnet deployment workflow
> rather than hold real value.

## Security notes

- `nonReentrant` guards on all state-changing user-facing functions.
- Reward accounting uses OpenZeppelin's `SafeERC20` for all token transfers.
- Owner-only `notifyRewardAmount` controls reward funding; stakers cannot
  affect the reward rate.

## License

MIT
