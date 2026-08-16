// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────
// BORROWED FROM OPENZEPPELIN — trusted machinery, just know the path
// ─────────────────────────────────────────────
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract StakingRewards is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────
    // CUSTOM LOGIC — state variables
    // ─────────────────────────────────────────────
    IERC20 public immutable stakingToken;   // token users deposit
    IERC20 public immutable rewardsToken;   // token they get paid in (can be same token)

    uint256 public rewardRate;              // reward tokens paid out per second, total, across all stakers
    uint256 public periodFinish;            // timestamp when the current reward period ends
    uint256 public lastUpdateTime;          // last time rewardPerTokenStored was refreshed
    uint256 public rewardPerTokenStored;    // the accumulator - cumulative reward per staked token, ever

    uint256 public totalSupply;             // total tokens staked in the whole contract
    mapping(address => uint256) public balanceOf;               // each user's staked balance
    mapping(address => uint256) public userRewardPerTokenPaid;  // accumulator value last time THIS user was updated
    mapping(address => uint256) public rewards;                 // rewards already earned but not yet claimed

    constructor(address _stakingToken, address _rewardsToken) Ownable(msg.sender) {
        stakingToken = IERC20(_stakingToken);
        rewardsToken = IERC20(_rewardsToken);
    }

    // ─────────────────────────────────────────────
    // CUSTOM LOGIC — the core accumulator math
    // ─────────────────────────────────────────────

    // rewardPerToken(): "as of right now, how much reward has accrued per single staked token,
    // cumulatively, since the contract began?"
    function rewardPerToken() public view returns (uint256) {
        if (totalSupply == 0) {
            return rewardPerTokenStored; // nobody staked, nothing to accrue against
        }
        return rewardPerTokenStored +
            (lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18 / totalSupply;
    }

    // caps time at periodFinish so rewards stop accruing once the funded period ends
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    // earned(): "how much reward does THIS user currently have coming to them?"
    function earned(address account) public view returns (uint256) {
        return (balanceOf[account] *
            (rewardPerToken() - userRewardPerTokenPaid[account]) / 1e18)
            + rewards[account];
    }

    // ─────────────────────────────────────────────
    // CUSTOM LOGIC — the modifier that ties it together
    // ─────────────────────────────────────────────

    // Runs before stake/withdraw/getReward/notifyRewardAmount.
    // Freezes the accumulator's current value into storage, and snapshots
    // this specific user's earned rewards, BEFORE their balance changes.
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    // ─────────────────────────────────────────────
    // CUSTOM LOGIC — user-facing actions
    // ─────────────────────────────────────────────

    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "cannot stake 0");
        totalSupply += amount;
        balanceOf[msg.sender] += amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        require(amount > 0, "cannot withdraw 0");
        totalSupply -= amount;
        balanceOf[msg.sender] -= amount;
        stakingToken.safeTransfer(msg.sender, amount);
    }

    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
        }
    }

    function exit() external {
        withdraw(balanceOf[msg.sender]);
        getReward();
    }

    // ─────────────────────────────────────────────
    // CUSTOM LOGIC — owner funds/starts a reward period
    // ─────────────────────────────────────────────

    function notifyRewardAmount(uint256 reward, uint256 duration)
        external onlyOwner updateReward(address(0))
    {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward / duration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / duration;
        }
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + duration;
    }
}