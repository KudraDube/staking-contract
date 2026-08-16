// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/StakingRewards.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @notice Same throwaway mintable ERC20 used in the test file. Deployed here
 * only when you don't point the script at real token addresses — useful for
 * Anvil and BSC testnet, where "real" tokens usually don't exist yet.
 */
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title DeployStakingRewards
 * @notice One script, three environments. The contract deployed is IDENTICAL
 * every time — only the RPC endpoint and env vars change between Anvil, BSC
 * testnet, and BSC mainnet. That's the point: by mainnet, this script has
 * already been exercised twice and should hold no surprises.
 *
 * Behaviour:
 *   - If STAKING_TOKEN / REWARDS_TOKEN env vars are unset, the script
 *     deploys fresh mock tokens for you (fine for Anvil/testnet, and fine
 *     for mainnet too if the point of this deploy is deployment reps rather
 *     than staking a specific real token).
 *   - If they ARE set (real token addresses), the script uses those instead
 *     — this is how you'd point at an actual BEP-20 pair on mainnet.
 */
contract DeployStakingRewards is Script {
    function run() external returns (StakingRewards stakingRewards) {
        // No PRIVATE_KEY env var anymore. When you run this with
        // --account <name> --sender <address>, Forge signs using the
        // encrypted keystore (cast wallet import) and prompts for your
        // password at broadcast time. msg.sender inside a Forge script
        // resolves to whatever address you passed via --sender.
        address deployer = msg.sender;

        address stakingTokenAddr = vm.envOr("STAKING_TOKEN", address(0));
        address rewardsTokenAddr = vm.envOr("REWARDS_TOKEN", address(0));

        bool usingMockStaking = stakingTokenAddr == address(0);
        bool usingMockRewards = rewardsTokenAddr == address(0);

        console.log("Deploying from:", deployer);
        console.log("Chain ID:", block.chainid);

        // Everything between startBroadcast/stopBroadcast is actually sent
        // as real transactions (or real Anvil-simulated ones), signed by
        // whichever keystore account --account/--sender point to. Nothing
        // before or after this block costs gas.
        vm.startBroadcast();

        if (usingMockStaking) {
            MockERC20 mockStaking = new MockERC20("Staking Token", "STK");
            stakingTokenAddr = address(mockStaking);
            console.log("Deployed mock STAKING token:", stakingTokenAddr);
        }

        if (usingMockRewards) {
            MockERC20 mockRewards = new MockERC20("Rewards Token", "RWD");
            rewardsTokenAddr = address(mockRewards);
            console.log("Deployed mock REWARDS token:", rewardsTokenAddr);
        }

        stakingRewards = new StakingRewards(stakingTokenAddr, rewardsTokenAddr);
        console.log("Deployed StakingRewards:", address(stakingRewards));

        // Only fires when we deployed the mock rewards token ourselves:
        // mint some to the deployer, then fund the StakingRewards contract
        // directly. Remember notifyRewardAmount() only does accounting —
        // it never pulls tokens in — so without this, getReward() would
        // revert the first time anyone tried to claim.
        if (usingMockRewards) {
            MockERC20(rewardsTokenAddr).mint(deployer, 10_000e18);
            MockERC20(rewardsTokenAddr).transfer(address(stakingRewards), 10_000e18);
            console.log("Funded StakingRewards with 10,000 mock reward tokens");
        }

        vm.stopBroadcast();
    }
}