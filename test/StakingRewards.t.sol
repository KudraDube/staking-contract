// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, stdError} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {StakingRewards} from "../src/StakingRewards.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev A token whose transfer functions call back into the staking contract (like a token with hooks).
contract HookToken is ERC20 {
    StakingRewards public target;
    uint256 public mode; // 1: re-enter stake during transferFrom. 2: re-enter getReward during transfer.
    bytes public lastError;

    constructor() ERC20("Hook Token", "HOOK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configure(StakingRewards target_, uint256 mode_) external {
        target = target_;
        mode = mode_;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (mode == 1) {
            try target.stake(1) {}
            catch (bytes memory err) {
                lastError = err;
            }
        }
        return super.transferFrom(from, to, value);
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (mode == 2) {
            try target.getReward() {}
            catch (bytes memory err) {
                lastError = err;
            }
        }
        return super.transfer(to, value);
    }
}

/// @dev Builds its own funded staking pool and drives random actions for the invariant tests.
contract StakingHandler is Test {
    StakingRewards public staking;
    MockERC20 public stakeToken;
    MockERC20 public rewardToken;
    address[] public actors;

    uint256 public constant FUNDED = 2_592_000 ether; // 30 days at 1 token per second
    uint256 public constant DURATION = 30 days;
    uint256 public ghostPaid;

    constructor() {
        stakeToken = new MockERC20("Stake", "STK");
        rewardToken = new MockERC20("Reward", "RWD");
        staking = new StakingRewards(address(stakeToken), address(rewardToken));

        rewardToken.mint(address(staking), FUNDED);
        staking.notifyRewardAmount(FUNDED, DURATION);

        for (uint256 i = 0; i < 3; i++) {
            address actor = makeAddr(string.concat("stakerActor", vm.toString(i)));
            actors.push(actor);
            stakeToken.mint(actor, 1_000_000 ether);
            vm.prank(actor);
            stakeToken.approve(address(staking), type(uint256).max);
        }
    }

    function stake(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 1, 1000 ether);
        vm.prank(actor);
        staking.stake(amount);
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        uint256 balance = staking.balanceOf(actor);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.prank(actor);
        staking.withdraw(amount);
    }

    function getReward(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 before = rewardToken.balanceOf(actor);
        vm.prank(actor);
        staking.getReward();
        ghostPaid += rewardToken.balanceOf(actor) - before;
    }

    function exitPool(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        if (staking.balanceOf(actor) == 0) return;
        uint256 before = rewardToken.balanceOf(actor);
        vm.prank(actor);
        staking.exit();
        ghostPaid += rewardToken.balanceOf(actor) - before;
    }

    function passTime(uint256 secondsToWait) external {
        secondsToWait = bound(secondsToWait, 1, 10 days);
        vm.warp(block.timestamp + secondsToWait);
    }

    function sumOfStakes() external view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += staking.balanceOf(actors[i]);
        }
    }

    function sumOfEarned() external view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += staking.earned(actors[i]);
        }
    }
}

contract StakingRewardsTest is Test {
    StakingRewards staking;
    MockERC20 stakeToken;
    MockERC20 rewardToken;
    StakingHandler handler;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address stranger = makeAddr("stranger");

    // The numbers from the Contracts Pack: 10 tokens per second for 100 seconds
    uint256 constant DURATION = 100;
    uint256 constant REWARD = 1000 ether;
    uint256 constant RATE = 10 ether;

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardNotified(uint256 reward, uint256 rewardRate, uint256 periodFinish);

    function setUp() public {
        stakeToken = new MockERC20("Stake", "STK");
        rewardToken = new MockERC20("Reward", "RWD");
        staking = new StakingRewards(address(stakeToken), address(rewardToken));

        address[2] memory users = [alice, bob];
        for (uint256 i = 0; i < users.length; i++) {
            stakeToken.mint(users[i], 1_000_000 ether);
            vm.prank(users[i]);
            stakeToken.approve(address(staking), type(uint256).max);
        }

        handler = new StakingHandler();
        targetContract(address(handler));
    }

    function _fund(uint256 reward, uint256 duration) internal {
        rewardToken.mint(address(staking), reward);
        staking.notifyRewardAmount(reward, duration);
    }

    function _stake(address user, uint256 amount) internal {
        vm.prank(user);
        staking.stake(amount);
    }

    // constructor

    function test_constructor_setsTokensAndOwner() public view {
        assertEq(address(staking.stakingToken()), address(stakeToken));
        assertEq(address(staking.rewardsToken()), address(rewardToken));
        assertEq(staking.owner(), address(this));
        assertEq(staking.totalSupply(), 0);
        assertEq(staking.rewardRate(), 0);
    }

    // stake

    function test_stake_movesTokensAndRecordsBalance() public {
        _stake(alice, 100 ether);

        assertEq(staking.balanceOf(alice), 100 ether);
        assertEq(staking.totalSupply(), 100 ether);
        assertEq(stakeToken.balanceOf(address(staking)), 100 ether);
        assertEq(stakeToken.balanceOf(alice), 1_000_000 ether - 100 ether);
    }

    function test_stake_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit Staked(alice, 100 ether);
        _stake(alice, 100 ether);
    }

    function test_stake_keepsUsersSeparate() public {
        _stake(alice, 100 ether);
        _stake(bob, 300 ether);

        assertEq(staking.balanceOf(alice), 100 ether);
        assertEq(staking.balanceOf(bob), 300 ether);
        assertEq(staking.totalSupply(), 400 ether);
    }

    function test_stake_revertsOnZero() public {
        vm.prank(alice);
        vm.expectRevert("cannot stake 0");
        staking.stake(0);
    }

    function test_stake_revertsWithoutAllowance() public {
        stakeToken.mint(stranger, 10 ether);
        vm.prank(stranger);
        vm.expectRevert();
        staking.stake(10 ether);
    }

    function test_stake_revertsWhenBalanceTooLow() public {
        vm.prank(stranger);
        vm.expectRevert();
        staking.stake(1);
    }

    // withdraw

    function test_withdraw_returnsTokensAndReducesBalance() public {
        _stake(alice, 100 ether);

        vm.prank(alice);
        staking.withdraw(40 ether);

        assertEq(staking.balanceOf(alice), 60 ether);
        assertEq(staking.totalSupply(), 60 ether);
        assertEq(stakeToken.balanceOf(alice), 1_000_000 ether - 60 ether);
    }

    function test_withdraw_emitsEvent() public {
        _stake(alice, 100 ether);

        vm.expectEmit(true, false, false, true);
        emit Withdrawn(alice, 40 ether);
        vm.prank(alice);
        staking.withdraw(40 ether);
    }

    function test_withdraw_revertsOnZero() public {
        _stake(alice, 100 ether);

        vm.prank(alice);
        vm.expectRevert("cannot withdraw 0");
        staking.withdraw(0);
    }

    function test_withdraw_revertsWhenAmountExceedsBalance() public {
        _stake(alice, 100 ether);

        vm.prank(alice);
        vm.expectRevert(stdError.arithmeticError);
        staking.withdraw(100 ether + 1);
    }

    function test_withdraw_cannotTakeAnotherUsersStake() public {
        _stake(alice, 100 ether);

        vm.prank(bob);
        vm.expectRevert(stdError.arithmeticError);
        staking.withdraw(1 ether);

        assertEq(staking.balanceOf(alice), 100 ether);
    }

    // notifyRewardAmount: access, the patch, and the maths

    function test_notify_setsRateAndPeriod() public {
        _fund(REWARD, DURATION);

        assertEq(staking.rewardRate(), RATE);
        assertEq(staking.periodFinish(), block.timestamp + DURATION);
        assertEq(staking.lastUpdateTime(), block.timestamp);
    }

    function test_notify_emitsEvent() public {
        rewardToken.mint(address(staking), REWARD);

        vm.expectEmit(false, false, false, true);
        emit RewardNotified(REWARD, RATE, block.timestamp + DURATION);
        staking.notifyRewardAmount(REWARD, DURATION);
    }

    function test_notify_onlyOwner() public {
        rewardToken.mint(address(staking), REWARD);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        staking.notifyRewardAmount(REWARD, DURATION);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staking.notifyRewardAmount(REWARD, DURATION);
    }

    // The three checks added by the pack patch

    function test_notify_revertsOnZeroDuration() public {
        rewardToken.mint(address(staking), REWARD);

        vm.expectRevert("duration is zero");
        staking.notifyRewardAmount(REWARD, 0);
    }

    function test_notify_revertsWhenRateRoundsToZero() public {
        rewardToken.mint(address(staking), REWARD);

        // 99 wei over 100 seconds is 0 per second
        vm.expectRevert("rate is zero");
        staking.notifyRewardAmount(99, DURATION);
    }

    function test_notify_revertsWhenContractCannotPayTheRate() public {
        rewardToken.mint(address(staking), REWARD - 1); // one wei short

        vm.expectRevert("reward too high");
        staking.notifyRewardAmount(REWARD, DURATION);
    }

    function test_notify_acceptsExactlyFundedAmount() public {
        _fund(REWARD, DURATION); // balance equals rate * duration exactly
        assertEq(staking.rewardRate() * DURATION, rewardToken.balanceOf(address(staking)));
    }

    function test_notify_midPeriodCarriesLeftoverIntoNewRate() public {
        _fund(REWARD, DURATION);
        _stake(alice, 100 ether);
        skip(50); // 500 ether still unpaid

        // Add 1500 more over a fresh 100 seconds: (1500 + 500) / 100 = 20 per second
        _fund(1500 ether, DURATION);

        assertEq(staking.rewardRate(), 20 ether);
        assertEq(staking.periodFinish(), block.timestamp + DURATION);

        // Alice was alone, so she should receive everything that was ever funded
        skip(DURATION);
        assertEq(staking.earned(alice), REWARD + 1500 ether);
    }

    function test_notify_leftoverCountsTowardsTheSolvencyCheck() public {
        _fund(REWARD, DURATION);
        skip(50); // 500 ether unpaid, balance is 1000 ether

        // rate = (600 + 500) / 10 = 110, so 1100 needed but only 1000 held
        vm.expectRevert("reward too high");
        staking.notifyRewardAmount(600 ether, 10);

        // rate = (500 + 500) / 10 = 100, so exactly 1000 needed and held
        staking.notifyRewardAmount(500 ether, 10);
        assertEq(staking.rewardRate(), 100 ether);
    }

    function test_notify_sameToken_depositsAreNotRewardMoney() public {
        MockERC20 token = new MockERC20("Same", "SAME");
        StakingRewards pool = new StakingRewards(address(token), address(token));

        token.mint(alice, 1000 ether);
        vm.startPrank(alice);
        token.approve(address(pool), type(uint256).max);
        pool.stake(1000 ether);
        vm.stopPrank();

        token.mint(address(pool), 100 ether); // 100 ether really set aside for rewards

        // The pool holds 1100 in total. Without the subtraction 101 would wrongly pass.
        vm.expectRevert("reward too high");
        pool.notifyRewardAmount(101 ether, 100);

        pool.notifyRewardAmount(100 ether, 100);
        assertEq(pool.rewardRate(), 1 ether);
    }

    // the accumulator: the Alice and Bob numbers from the pack

    function test_packExample_aliceAndBobEarnTheDocumentedAmounts() public {
        _fund(REWARD, DURATION);

        _stake(alice, 100 ether); // time 0
        skip(10);
        assertEq(staking.rewardPerToken(), 1 ether); // 100 reward over 100 staked

        _stake(bob, 100 ether); // time 10
        skip(10); // time 20
        assertEq(staking.rewardPerToken(), 1.5 ether);

        assertEq(staking.earned(alice), 150 ether);
        assertEq(staking.earned(bob), 50 ether);
        assertEq(staking.earned(alice) + staking.earned(bob), 200 ether); // 20 seconds x 10
    }

    function test_accrual_stopsAtPeriodFinish() public {
        _fund(REWARD, DURATION);
        _stake(alice, 100 ether);

        skip(DURATION);
        uint256 atEnd = staking.earned(alice);
        assertEq(atEnd, REWARD);

        skip(10_000);
        assertEq(staking.earned(alice), atEnd);
    }

    function test_accrual_nothingBeforeAPeriodIsFunded() public {
        _stake(alice, 100 ether);
        skip(1000);

        assertEq(staking.earned(alice), 0);
        assertEq(staking.rewardPerToken(), 0);
    }

    function test_accrual_accumulatorStandsStillWhenNobodyIsStaked() public {
        _fund(REWARD, DURATION);
        skip(50);

        // No division by zero, and nothing accrues against an empty pool
        assertEq(staking.rewardPerToken(), 0);

        _stake(alice, 100 ether);
        skip(50);

        // Alice only earns the second half. The first 500 ether is stranded in the contract.
        assertEq(staking.earned(alice), 500 ether);
    }

    function test_accrual_lateStakerDoesNotEarnForThePast() public {
        _fund(REWARD, DURATION);
        _stake(alice, 100 ether);
        skip(60);

        _stake(bob, 100 ether);
        assertEq(staking.earned(bob), 0);
    }

    function test_accrual_stopsAfterWithdrawingEverything() public {
        _fund(REWARD, DURATION);
        _stake(alice, 100 ether);
        skip(10);

        vm.prank(alice);
        staking.withdraw(100 ether);
        uint256 banked = staking.earned(alice);
        assertEq(banked, 100 ether);

        skip(50);
        assertEq(staking.earned(alice), banked);
    }

    function test_accrual_changingStakeSettlesTheOldBalanceFirst() public {
        _fund(REWARD, DURATION);
        _stake(alice, 100 ether);
        _stake(bob, 100 ether);
        skip(10); // each has earned 50

        _stake(alice, 100 ether); // alice now 200 of 300
        skip(10);

        // Second window: 100 reward split 2/3 and 1/3
        uint256 window = 100 ether;
        assertApproxEqAbs(staking.earned(alice), 50 ether + (window * 2) / 3, 1e6);
        assertApproxEqAbs(staking.earned(bob), 50 ether + window / 3, 1e6);
    }

    // getReward and exit

    function test_getReward_paysAndZeroesBalance() public {
        _fund(REWARD, DURATION);
        _stake(alice, 100 ether);
        skip(DURATION);

        vm.prank(alice);
        staking.getReward();

        assertEq(rewardToken.balanceOf(alice), REWARD);
        assertEq(staking.rewards(alice), 0);
        assertEq(staking.earned(alice), 0);
    }

    function test_getReward_emitsEvent() public {
        _fund(REWARD, DURATION);
        _stake(alice, 100 ether);
        skip(DURATION);

        vm.expectEmit(true, false, false, true);
        emit RewardPaid(alice, REWARD);
        vm.prank(alice);
        staking.getReward();
    }

    function test_getReward_secondClaimPaysNothing() public {
        _fund(REWARD, DURATION);
        _stake(alice, 100 ether);
        skip(DURATION);

        vm.startPrank(alice);
        staking.getReward();
        staking.getReward();
        vm.stopPrank();

        assertEq(rewardToken.balanceOf(alice), REWARD); // paid exactly once
    }

    function test_getReward_withNothingEarnedDoesNotRevert() public {
        vm.prank(alice);
        staking.getReward();

        assertEq(rewardToken.balanceOf(alice), 0);
    }

    function test_getReward_doesNotAffectStake() public {
        _fund(REWARD, DURATION);
        _stake(alice, 100 ether);
        skip(10);

        vm.prank(alice);
        staking.getReward();

        assertEq(staking.balanceOf(alice), 100 ether);
        assertEq(staking.totalSupply(), 100 ether);
    }

    function test_exit_returnsStakeAndRewards() public {
        _fund(REWARD, DURATION);
        _stake(alice, 100 ether);
        skip(DURATION);

        vm.prank(alice);
        staking.exit();

        assertEq(stakeToken.balanceOf(alice), 1_000_000 ether);
        assertEq(rewardToken.balanceOf(alice), REWARD);
        assertEq(staking.balanceOf(alice), 0);
        assertEq(staking.totalSupply(), 0);
    }

    function test_exit_revertsWithNothingStaked() public {
        vm.prank(alice);
        vm.expectRevert("cannot withdraw 0");
        staking.exit();
    }

    // reentrancy

    function test_reentrancy_stakingTokenCannotReenterStake() public {
        HookToken hook = new HookToken();
        StakingRewards pool = new StakingRewards(address(hook), address(rewardToken));
        hook.mint(alice, 1000 ether);
        hook.configure(pool, 1);

        vm.startPrank(alice);
        hook.approve(address(pool), type(uint256).max);
        pool.stake(100 ether);
        vm.stopPrank();

        assertEq(hook.lastError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(pool.totalSupply(), 100 ether); // only the real stake counted
    }

    function test_reentrancy_rewardsTokenCannotReenterGetReward() public {
        HookToken hook = new HookToken();
        StakingRewards pool = new StakingRewards(address(stakeToken), address(hook));
        hook.mint(address(pool), REWARD);
        pool.notifyRewardAmount(REWARD, DURATION);

        vm.startPrank(alice);
        stakeToken.approve(address(pool), type(uint256).max);
        pool.stake(100 ether);
        vm.stopPrank();
        skip(DURATION);

        hook.configure(pool, 2); // the token now tries to claim again while it is being paid out
        vm.prank(alice);
        pool.getReward();

        assertEq(hook.lastError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(hook.balanceOf(alice), REWARD); // paid exactly once
        assertEq(pool.rewards(alice), 0);
    }

    // fuzz tests

    function testFuzz_stakeThenWithdrawReturnsExactStake(uint256 amount, uint256 waitTime) public {
        amount = bound(amount, 1, 1_000_000 ether);
        waitTime = bound(waitTime, 0, 365 days);
        _fund(REWARD, DURATION);

        _stake(alice, amount);
        skip(waitTime);
        vm.prank(alice);
        staking.withdraw(amount);

        assertEq(stakeToken.balanceOf(alice), 1_000_000 ether);
        assertEq(staking.totalSupply(), 0);
    }

    function testFuzz_rewardsNeverExceedFundingAndAlmostAllIsPaid(uint256 aliceAmount, uint256 bobAmount, uint256 joinDelay)
        public
    {
        aliceAmount = bound(aliceAmount, 1 ether, 1_000_000 ether);
        bobAmount = bound(bobAmount, 1 ether, 1_000_000 ether);
        joinDelay = bound(joinDelay, 0, DURATION);
        _fund(REWARD, DURATION);

        _stake(alice, aliceAmount); // alice is in from the very start, so no reward is stranded
        skip(joinDelay);
        _stake(bob, bobAmount);
        skip(DURATION); // past the end of the period

        uint256 total = staking.earned(alice) + staking.earned(bob);
        assertLe(total, REWARD); // never promises more than was funded
        assertGe(total, REWARD - 1e8); // only rounding dust is left behind
    }

    function testFuzz_largerStakeEarnsMoreOverTheSameTime(uint256 smallStake, uint256 extra) public {
        smallStake = bound(smallStake, 1 ether, 1000 ether);
        extra = bound(extra, 1 ether, 1000 ether);
        _fund(REWARD, DURATION);

        _stake(alice, smallStake);
        _stake(bob, smallStake + extra);
        skip(DURATION);

        assertGe(staking.earned(bob), staking.earned(alice));
    }

    // invariants (run against the handler's own funded pool)

    function invariant_stakingTokenBalanceEqualsTotalSupply() public view {
        assertEq(handler.stakeToken().balanceOf(address(handler.staking())), handler.staking().totalSupply());
    }

    function invariant_totalSupplyEqualsSumOfStakes() public view {
        assertEq(handler.staking().totalSupply(), handler.sumOfStakes());
    }

    function invariant_rewardsOwedPlusPaidNeverExceedFunding() public view {
        assertLe(handler.ghostPaid() + handler.sumOfEarned(), handler.FUNDED());
    }

    function invariant_rewardTokensAreConserved() public view {
        assertEq(handler.rewardToken().balanceOf(address(handler.staking())) + handler.ghostPaid(), handler.FUNDED());
    }
}
