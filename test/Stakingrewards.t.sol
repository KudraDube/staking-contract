// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// forge-std/Test.sol gives us the testing framework itself: assertEq, vm (the
// "cheatcode" interface for warping time, pranking addresses, etc.), and the
// Test base contract we inherit from.
import "forge-std/Test.sol";

// This is the real contract we're testing. Adjust the path if your Foundry
// project structure differs (this assumes the standard src/ + test/ layout).
import "../src/StakingRewards.sol";

// We need real ERC20 tokens to stake and to pay rewards with. OpenZeppelin's
// ERC20 gives us the standard behaviour (transfer, approve, transferFrom) for
// free — we just add a mint() function so the test can hand out tokens.
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @notice A minimal mintable ERC20, used ONLY in tests. Real staking/reward
 * tokens in production would already exist (e.g. a real project token) — this
 * mock exists purely so we have something to transfer and approve in the test
 * environment.
 */
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title StakingRewardsTest
 * @notice Tests for the StakingRewards accumulator contract.
 *
 * Foundry convention: any function starting with `test_` is automatically
 * run as its own isolated test. Each test gets a FRESH copy of the state set
 * up in setUp() — tests never see each other's side effects.
 */
contract StakingRewardsTest is Test {
    StakingRewards public stakingRewards;
    MockERC20 public stakingToken;
    MockERC20 public rewardsToken;

    // makeAddr() is a Foundry cheatcode that deterministically generates a
    // labeled address from a string. Using labels instead of raw addresses
    // makes trace output ("alice did X") readable instead of showing 0x1234...
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    /**
     * @dev setUp() runs before EVERY test function. Think of it as the
     * "arrange" step that's common to all your tests: deploy contracts,
     * fund accounts, set approvals.
     */
    function setUp() public {
        // Deploy two independent mock tokens: one to stake, one to earn.
        // In the real StakingRewards contract these can be the same token
        // or different tokens — the contract doesn't care.
        stakingToken = new MockERC20("Staking Token", "STK");
        rewardsToken = new MockERC20("Rewards Token", "RWD");

        // Deploy the contract under test. The test contract itself
        // (address(this)) becomes the owner, since Ownable(msg.sender) in
        // the constructor captures whoever deploys it.
        stakingRewards = new StakingRewards(address(stakingToken), address(rewardsToken));

        // Give Alice and Bob staking tokens to work with.
        stakingToken.mint(alice, 1_000e18);
        stakingToken.mint(bob, 1_000e18);

        // Mint reward tokens to the owner (this test contract), then hand
        // them over to the StakingRewards contract itself. This matters:
        // notifyRewardAmount() only does ACCOUNTING (it sets rewardRate) —
        // it does NOT pull tokens in. The contract must already hold enough
        // rewardsToken balance, or getReward() will revert when it tries to
        // pay someone out. Funding it here means later tests that call
        // getReward() won't fail for an unrelated reason.
        rewardsToken.mint(address(this), 10_000e18);
        rewardsToken.transfer(address(stakingRewards), 10_000e18);

        // Alice and Bob each need to approve the contract to move THEIR
        // staking tokens on their behalf, since stake() calls
        // safeTransferFrom(msg.sender, ...). vm.prank(x) makes the NEXT
        // call appear to come from address x — it's how we simulate
        // "acting as Alice" without needing her private key.
        vm.prank(alice);
        stakingToken.approve(address(stakingRewards), type(uint256).max);

        vm.prank(bob);
        stakingToken.approve(address(stakingRewards), type(uint256).max);
    }

    /**
     * @notice Sanity check: a single staker, alone for the whole reward
     * period, should earn exactly the full reward pool. No accumulator
     * complexity yet — this just confirms the basic wiring works before we
     * test the harder staggered-staker case.
     */
    function test_SingleStaker_EarnsFullRewardPool() public {
        uint256 rewardAmount = 1_000e18;
        uint256 duration = 1000; // seconds

        // Owner starts a reward period: 1000 tokens paid out over 1000
        // seconds -> rewardRate = 1e18 (1 token/second, in wei terms).
        stakingRewards.notifyRewardAmount(rewardAmount, duration);

        vm.prank(alice);
        stakingRewards.stake(100e18);

        // Fast-forward to the exact end of the reward period.
        // vm.warp(x) sets block.timestamp to x for all subsequent calls.
        vm.warp(block.timestamp + duration);

        // Alice was the only staker for the entire period, so she should
        // have earned the entire reward pool.
        assertEq(stakingRewards.earned(alice), rewardAmount, "sole staker should earn the full pool");
    }

    /**
     * @notice THE priority test for this contract type. This is what the
     * accumulator pattern (rewardPerTokenStored + userRewardPerTokenPaid)
     * exists to solve: fairly splitting rewards between stakers who joined
     * at DIFFERENT times, without looping over every staker on every call.
     *
     * Scenario:
     *   - Reward period: 1000 tokens over 1000 seconds -> rewardRate = 1e18/sec
     *   - t=0:    Alice stakes 100e18, alone.
     *   - t=500:  Bob stakes 100e18. Alice has already earned 500 tokens
     *             solo (500 seconds * 1 token/sec).
     *   - t=1000: Period ends. During the second 500 seconds, Alice and Bob
     *             have EQUAL stakes, so they split that half's 500 tokens
     *             evenly: 250 each.
     *
     * Hand-calculated expected result:
     *   Alice: 500 (solo half) + 250 (shared half) = 750 tokens
     *   Bob:   0   (wasn't staked yet) + 250 (shared half) = 250 tokens
     *   Total: 750 + 250 = 1000 tokens = the full reward pool. Nothing lost,
     *   nothing double-counted — that's the invariant this test is really
     *   checking.
     */
    function test_StaggeredStakers_EarnProportionalRewards() public {
        uint256 rewardAmount = 1_000e18;
        uint256 duration = 1000; // seconds

        // Start the reward period. rewardRate = 1000e18 / 1000 = 1e18/sec.
        stakingRewards.notifyRewardAmount(rewardAmount, duration);

        // --- t=0: Alice stakes alone ---
        vm.prank(alice);
        stakingRewards.stake(100e18);

        // --- advance 500 seconds: only Alice has been earning ---
        vm.warp(block.timestamp + 500);

        // --- t=500: Bob joins. His stake() call triggers updateReward(bob),
        // which snapshots the CURRENT rewardPerTokenStored into
        // userRewardPerTokenPaid[bob]. That snapshot is what excludes Bob
        // from the rewards Alice already earned before he arrived. ---
        vm.prank(bob);
        stakingRewards.stake(100e18);

        // --- advance the remaining 500 seconds to the end of the period ---
        vm.warp(block.timestamp + 500);

        uint256 aliceEarned = stakingRewards.earned(alice);
        uint256 bobEarned = stakingRewards.earned(bob);

        // Alice: 500 tokens solo + 250 tokens shared = 750 tokens
        assertEq(aliceEarned, 750e18, "Alice should earn the solo half plus half of the shared half");

        // Bob: 0 tokens solo (wasn't staked) + 250 tokens shared = 250 tokens
        assertEq(bobEarned, 250e18, "Bob should only earn from the period after he staked, split evenly with Alice");

        // The core invariant: total rewards paid out never exceeds (or falls
        // short of) what notifyRewardAmount actually allocated, regardless
        // of when each staker joined.
        assertEq(aliceEarned + bobEarned, rewardAmount, "combined earned must equal the full reward pool");
    }

    /**
     * @notice Confirms getReward() actually moves tokens, not just updates
     * internal accounting. earned() being correct doesn't guarantee the
     * payout function works — this closes that gap.
     */
    function test_GetReward_TransfersEarnedTokensToStaker() public {
        stakingRewards.notifyRewardAmount(1_000e18, 1000);

        vm.prank(alice);
        stakingRewards.stake(100e18);

        vm.warp(block.timestamp + 1000);

        uint256 expectedReward = stakingRewards.earned(alice);
        uint256 balanceBefore = rewardsToken.balanceOf(alice);

        vm.prank(alice);
        stakingRewards.getReward();

        uint256 balanceAfter = rewardsToken.balanceOf(alice);

        assertEq(balanceAfter - balanceBefore, expectedReward, "getReward should transfer exactly the earned amount");
        assertEq(stakingRewards.rewards(alice), 0, "rewards should be zeroed out after claiming");
    }
}