// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/math/Math.sol';
import '@openzeppelin/contracts/access/Ownable.sol';

contract MasterChefBnb is Ownable {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
  event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
  event Claim(address indexed user, uint256 indexed pid, uint256 amount);
  event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

  /// @notice Detail of each user.
  struct UserInfo {
    uint256 amount; // Number of tokens staked
    uint256 rewardDebt; // A base for future reward claims. Works as a threshold, updated on each reward claim
    //
    // At any point in time, pending user reward for a given pool is:
    // pending reward = (user.amount * pool.accRewardPerShare) - user.rewardFloor
    //
    // Whenever a user deposits or withdraws a pool token:
    //   1. The pool's `accRewardPerShare` (and `lastUpdate`) gets updated.
    //   2. User receives the pending reward sent to their address.
    //   3. User's `amount` gets updated.
    //   4. User's `rewardFloor` gets updated.
  }

  /// @notice Detail of each pool.
  struct PoolInfo {
    address token; // Token to stake.
    uint256 allocPoint; // How many allocation points assigned to this pool. Rewards to distribute per second.
    uint256 lastUpdateTime; // Last time that distribution happened.
    uint256 accRewardPerShare; // Accumulated rewards per share.
    uint256 totalStaked; // Amount of tokens staked in the pool.
    uint256 accUndistributedReward; // Accumulated rewards when a pool has no stake in it.
  }

  /// @dev Division precision.
  uint256 private precision = 1e18;

  /// @dev Reward token balance.
  uint256 public rewardTokenBalance;

  /// @notice Total allocation points. Must be the sum of all allocation points in all pools.
  uint256 public totalAllocPoint;

  /// @notice Time of the contract deployment.
  uint256 public timeDeployed;

  /// @notice Total rewards accumulated since contract deployment.
  uint256 public totalRewards;

  /// @notice Reward token.
  address public rewardToken;

  address public rewardDistributor;

  /// @notice Detail of each pool.
  PoolInfo[] public poolInfo;

  /// @notice Period in which the latest distribution of rewards will end.
  uint256 public periodFinish;

  /// @notice Reward rate per second. Has increased precision (when doing math with it, do div(precision))
  uint256 public rewardRate;

  ///  @notice New rewards are equaly split between the duration.
  uint256 public rewardsDuration;

  /// @notice Detail of each user who stakes tokens.
  mapping(uint256 => mapping(address => UserInfo)) public userInfo;
  mapping(address => bool) private poolToken;

  modifier onlyAuthorized() {
    require(msg.sender == rewardDistributor, 'MasterChefBnb: Caller not authorized');
    _;
  }

  constructor(address _rewardToken, uint256 _rewardsDuration) public {
    rewardToken = _rewardToken;

    rewardsDuration = _rewardsDuration;
    timeDeployed = block.timestamp;
    periodFinish = timeDeployed.add(rewardsDuration);
  }

  function setRewardDistributor(address account) external onlyOwner {
    rewardDistributor = account;
  }

  /// @notice Average reward per second generated since contract deployment.
  function avgRewardsPerSecondTotal() external view returns (uint256 avgPerSecond) {
    return totalRewards.div(block.timestamp.sub(timeDeployed));
  }

  /// @notice Total pools.
  function poolLength() external view returns (uint256) {
    return poolInfo.length;
  }

  /// @notice Display user rewards for a specific pool.
  function pendingReward(uint256 _pid, address _user) public view returns (uint256) {
    PoolInfo storage pool = poolInfo[_pid];
    UserInfo storage user = userInfo[_pid][_user];
    uint256 accRewardPerShare = pool.accRewardPerShare;

    if (pool.totalStaked != 0 && totalAllocPoint != 0) {
      accRewardPerShare = accRewardPerShare.add(
        _getPoolRewardsSinceLastUpdate(_pid).mul(precision).div(pool.totalStaked)
      );
    }

    return user.amount.mul(accRewardPerShare).div(precision).sub(user.rewardDebt);
  }

  /// @notice Add a new pool.
  function add(
    uint256 _allocPoint,
    address _token,
    bool _withUpdate
  ) public onlyOwner {
    if (_withUpdate) {
      massUpdatePools();
    }

    require(
      poolToken[address(_token)] == false,
      'MasterChefBnb: Stake token has already been added'
    );

    totalAllocPoint = totalAllocPoint.add(_allocPoint);

    poolInfo.push(
      PoolInfo({
        token: _token,
        allocPoint: _allocPoint,
        lastUpdateTime: block.timestamp,
        accRewardPerShare: 0,
        totalStaked: 0,
        accUndistributedReward: 0
      })
    );

    poolToken[address(_token)] = true;
  }

  /// @notice Update the given pool's allocation point.
  function set(
    uint256 _pid,
    uint256 _allocPoint,
    bool _withUpdate
  ) public onlyOwner {
    if (_withUpdate) {
      massUpdatePools();
    }

    totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
    poolInfo[_pid].allocPoint = _allocPoint;
  }

  /// @notice Deposit tokens to pool for reward allocation.
  function deposit(uint256 _pid, uint256 _amount) public {
    PoolInfo storage pool = poolInfo[_pid];
    UserInfo storage user = userInfo[_pid][msg.sender];

    _updatePool(_pid);

    uint256 pending;

    if (pool.totalStaked == 0) {
      // Special case: no one was staking, the pool was accumulating rewards.
      pending = pool.accUndistributedReward;
      pool.accUndistributedReward = 0;
    }
    if (user.amount != 0) {
      pending = _getUserPendingReward(_pid);
    }

    _claimFromPool(_pid, pending);
    _transferAmountIn(_pid, _amount);
    _updateRewardDebt(_pid);

    emit Deposit(msg.sender, _pid, _amount);
  }

  // Withdraw tokens from pool. Claims rewards implicitly (only claims rewards when called with _amount = 0)
  function withdraw(uint256 _pid, uint256 _amount) public {
    UserInfo storage user = userInfo[_pid][msg.sender];
    require(user.amount >= _amount, 'MasterChefBnb: Withdraw amount is greater than user stake.');

    _updatePool(_pid);
    _claimFromPool(_pid, _getUserPendingReward(_pid));
    _transferAmountOut(_pid, _amount);
    _updateRewardDebt(_pid);

    emit Withdraw(msg.sender, _pid, _amount);
  }

  // Withdraw without caring about rewards. EMERGENCY ONLY.
  // !Caution this will remove all your pending rewards!
  function emergencyWithdraw(uint256 _pid) public {
    PoolInfo storage pool = poolInfo[_pid];
    UserInfo storage user = userInfo[_pid][msg.sender];

    uint256 _amount = user.amount;
    user.amount = 0;
    user.rewardDebt = 0;
    pool.totalStaked = pool.totalStaked.sub(_amount);

    IERC20(pool.token).safeTransfer(address(msg.sender), _amount);
    emit EmergencyWithdraw(msg.sender, _pid, _amount);
    // No mass update dont update pending rewards
  }

  /// Adds and evenly distributes any rewards that were sent to the contract since last reward update.
  function updateRewards(uint256 amount) external onlyAuthorized {
    require(amount != 0, 'MasterChefBnb: Reward amount must be greater than zero');

    IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), amount);
    rewardTokenBalance = rewardTokenBalance.add(amount);

    if (totalAllocPoint == 0) {
      return;
    }

    massUpdatePools();

    // note: if increasing rewards after the last period has ended, just divide the amount by period length
    if (block.timestamp >= periodFinish) {
      rewardRate = amount.mul(precision).div(rewardsDuration);
    } else {
      uint256 periodSecondsLeft = periodFinish.sub(block.timestamp);
      uint256 periodRewardsLeft = periodSecondsLeft.mul(rewardRate);
      rewardRate = periodRewardsLeft.add(amount.mul(precision)).div(rewardsDuration);
    }

    totalRewards = totalRewards.add(amount);
    periodFinish = block.timestamp.add(rewardsDuration);
  }

  /// @notice Updates rewards for all pools by adding pending rewards.
  /// Can spend a lot of gas.
  function massUpdatePools() public {
    uint256 length = poolInfo.length;
    for (uint256 pid = 0; pid < length; ++pid) {
      _updatePool(pid);
    }
  }

  /// @notice Keeps pool properties (lastUpdateTime, accRewardPerShare, accUndistributedReward) up to date.
  function _updatePool(uint256 _pid) internal {
    if (totalAllocPoint == 0) return;

    PoolInfo storage pool = poolInfo[_pid];
    uint256 poolRewards = _getPoolRewardsSinceLastUpdate(_pid);

    if (pool.totalStaked == 0) {
      pool.accRewardPerShare = pool.accRewardPerShare.add(poolRewards);
      pool.accUndistributedReward = pool.accUndistributedReward.add(poolRewards);
    } else {
      pool.accRewardPerShare = pool.accRewardPerShare.add(
        poolRewards.mul(precision).div(pool.totalStaked)
      );
    }

    pool.lastUpdateTime = block.timestamp;
  }

  function _getPoolRewardsSinceLastUpdate(uint256 _pid)
    internal
    view
    returns (uint256 _poolRewards)
  {
    PoolInfo storage pool = poolInfo[_pid];
    uint256 lastTimeRewardApplicable = Math.min(block.timestamp, periodFinish);
    uint256 numSeconds = Math.max(lastTimeRewardApplicable.sub(pool.lastUpdateTime), 0);
    return numSeconds.mul(rewardRate).mul(pool.allocPoint).div(totalAllocPoint).div(precision);
  }

  function _safeRewardTokenTransfer(address _to, uint256 _amount)
    internal
    returns (uint256 _claimed)
  {
    _claimed = Math.min(_amount, rewardTokenBalance);
    IERC20(rewardToken).transfer(_to, _claimed);
    rewardTokenBalance = rewardTokenBalance.sub(_claimed);
  }

  function withdrawStuckTokens(address _token, uint256 _amount) public onlyOwner {
    require(_token != address(rewardToken), 'MasterChefBnb: Cannot withdraw reward tokens');
    require(poolToken[address(_token)] == false, 'MasterChefBnb: Cannot withdraw stake tokens');
    IERC20(_token).safeTransfer(msg.sender, _amount);
  }

  function _getUserPendingReward(uint256 _pid) internal view returns (uint256 _reward) {
    PoolInfo storage pool = poolInfo[_pid];
    UserInfo storage user = userInfo[_pid][msg.sender];
    return user.amount.mul(pool.accRewardPerShare).div(precision).sub(user.rewardDebt);
  }

  function _claimFromPool(uint256 _pid, uint256 _amount) internal {
    if (_amount != 0) {
      uint256 amountClaimed = _safeRewardTokenTransfer(msg.sender, _amount);
      emit Claim(msg.sender, _pid, amountClaimed);
    }
  }

  function _transferAmountIn(uint256 _pid, uint256 _amount) internal {
    PoolInfo storage pool = poolInfo[_pid];
    UserInfo storage user = userInfo[_pid][msg.sender];

    if (_amount != 0) {
      IERC20(pool.token).safeTransferFrom(msg.sender, address(this), _amount);
      user.amount = user.amount.add(_amount);
      pool.totalStaked = pool.totalStaked.add(_amount);
    }
  }

  function _transferAmountOut(uint256 _pid, uint256 _amount) internal {
    PoolInfo storage pool = poolInfo[_pid];
    UserInfo storage user = userInfo[_pid][msg.sender];

    if (_amount != 0) {
      IERC20(pool.token).safeTransfer(msg.sender, _amount);
      user.amount = user.amount.sub(_amount);
      pool.totalStaked = pool.totalStaked.sub(_amount);
    }
  }

  function _updateRewardDebt(uint256 _pid) internal {
    UserInfo storage user = userInfo[_pid][msg.sender];
    user.rewardDebt = user.amount.mul(poolInfo[_pid].accRewardPerShare).div(precision);
  }
}
