// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/utils/EnumerableSet.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import './RocketToken.sol';

// MasterChef is the master of Rocket. He can make Rocket and he is a fair guy.
contract MasterChefRokt is Ownable {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  // Info of each user.
  struct UserInfo {
    uint256 amount; // How many LP tokens the user has provided.
    uint256 rewardDebt; // Reward debt. See explanation below.
    //
    // We do some fancy math here. Basically, any point in time, the amount of Rockets
    // entitled to a user but is pending to be distributed is:
    //
    //   pending reward = (user.amount * pool.accRocketPerShare) - user.rewardDebt
    //
    // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
    //   1. The pool's `accRocketPerShare` (and `lastRewardBlock`) gets updated.
    //   2. User receives the pending reward sent to his/her address.
    //   3. User's `amount` gets updated.
    //   4. User's `rewardDebt` gets updated.
  }

  // Info of each pool.
  struct PoolInfo {
    IERC20 lpToken; // Address of LP token contract.
    uint256 allocPoint; // How many allocation points assigned to this pool. Rockets to distribute per block.
    uint256 lastRewardBlock; // Last block number that Rockets distribution occurs.
    uint256 accRocketPerShare; // Accumulated Rockets per share, times 1e12. See below.
  }

  // The Rocket TOKEN!
  RocketToken public rocket;
  // Block number when bonus Rocket period ends.
  uint256 public bonusEndBlock;
  // Rocket tokens created per block.
  uint256 public rocketPerBlock;
  // Bonus muliplier for early rocket makers.
  uint256 public constant BONUS_MULTIPLIER = 2;
  // Total allocation poitns. Must be the sum of all allocation points in all pools.
  uint256 public totalAllocPoint = 0;
  // The block number when Rocket mining starts.
  uint256 public startBlock;
  address public reactor;
  address public treasury;

  // Info of each pool.
  PoolInfo[] public poolInfo;
  // Info of each user that stakes LP tokens.
  mapping(uint256 => mapping(address => UserInfo)) public userInfo;

  event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
  event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
  event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

  constructor(
    RocketToken _rocket,
    uint256 _rocketPerBlock,
    uint256 _startBlock,
    uint256 _bonusEndBlock,
    address _reactor,
    address _treasury
  ) public {
    rocket = _rocket;
    reactor = _reactor;
    treasury = _treasury;
    rocketPerBlock = _rocketPerBlock;
    bonusEndBlock = _bonusEndBlock;
    startBlock = _startBlock;
  }

  function poolLength() external view returns (uint256) {
    return poolInfo.length;
  }

  // Add a new lp to the pool. Can only be called by the owner.
  // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
  function add(
    uint256 _allocPoint,
    IERC20 _lpToken,
    bool _withUpdate
  ) public onlyOwner {
    if (_withUpdate) {
      massUpdatePools();
    }
    uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
    totalAllocPoint = totalAllocPoint.add(_allocPoint);
    poolInfo.push(
      PoolInfo({
        lpToken: _lpToken,
        allocPoint: _allocPoint,
        lastRewardBlock: lastRewardBlock,
        accRocketPerShare: 0
      })
    );
  }

  // Update the given pool's Rocket allocation point. Can only be called by the owner.
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

  // Return reward multiplier over the given _from to _to block.
  function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
    if (_to <= bonusEndBlock) {
      return _to.sub(_from).mul(BONUS_MULTIPLIER);
    } else if (_from >= bonusEndBlock) {
      return _to.sub(_from);
    } else {
      return bonusEndBlock.sub(_from).mul(BONUS_MULTIPLIER).add(_to.sub(bonusEndBlock));
    }
  }

  // View function to see pending Rockets on frontend.
  function pendingReward(uint256 _pid, address _user) external view returns (uint256) {
    PoolInfo storage pool = poolInfo[_pid];
    UserInfo storage user = userInfo[_pid][_user];
    uint256 accRocketPerShare = pool.accRocketPerShare;
    uint256 lpSupply = pool.lpToken.balanceOf(address(this));
    if (block.number > pool.lastRewardBlock && lpSupply != 0) {
      uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
      uint256 rocketReward =
        multiplier.mul(rocketPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
      accRocketPerShare = accRocketPerShare.add(rocketReward.mul(1e12).div(lpSupply));
    }
    return user.amount.mul(accRocketPerShare).div(1e12).sub(user.rewardDebt);
  }

  // Update reward vairables for all pools. Be careful of gas spending!
  function massUpdatePools() public {
    uint256 length = poolInfo.length;
    for (uint256 pid = 0; pid < length; ++pid) {
      updatePool(pid);
    }
  }

  // Update reward variables of the given pool to be up-to-date.
  function updatePool(uint256 _pid) public {
    PoolInfo storage pool = poolInfo[_pid];
    if (block.number <= pool.lastRewardBlock) {
      return;
    }
    uint256 lpSupply = pool.lpToken.balanceOf(address(this));
    if (lpSupply == 0) {
      pool.lastRewardBlock = block.number;
      return;
    }
    uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
    uint256 rocketReward = multiplier.mul(rocketPerBlock).mul(pool.allocPoint).div(totalAllocPoint);

    rocket.mint(reactor, rocketReward.div(10));
    rocket.mint(treasury, rocketReward.div(20).mul(5));
    rocket.mint(address(this), rocketReward);

    pool.accRocketPerShare = pool.accRocketPerShare.add(rocketReward.mul(1e12).div(lpSupply));
    pool.lastRewardBlock = block.number;
  }

  // Deposit LP tokens to MasterChef for Rocket allocation.
  function deposit(uint256 _pid, uint256 _amount) public {
    PoolInfo storage pool = poolInfo[_pid];
    UserInfo storage user = userInfo[_pid][msg.sender];
    updatePool(_pid);
    if (user.amount > 0) {
      uint256 pending = user.amount.mul(pool.accRocketPerShare).div(1e12).sub(user.rewardDebt);
      safeRocketTransfer(msg.sender, pending);
    }
    pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
    user.amount = user.amount.add(_amount);
    user.rewardDebt = user.amount.mul(pool.accRocketPerShare).div(1e12);
    emit Deposit(msg.sender, _pid, _amount);
  }

  // Withdraw LP tokens from MasterChef.
  function withdraw(uint256 _pid, uint256 _amount) public {
    PoolInfo storage pool = poolInfo[_pid];
    UserInfo storage user = userInfo[_pid][msg.sender];
    require(user.amount >= _amount, 'withdraw: not good');
    updatePool(_pid);
    uint256 pending = user.amount.mul(pool.accRocketPerShare).div(1e12).sub(user.rewardDebt);
    safeRocketTransfer(msg.sender, pending);
    user.amount = user.amount.sub(_amount);
    user.rewardDebt = user.amount.mul(pool.accRocketPerShare).div(1e12);
    pool.lpToken.safeTransfer(address(msg.sender), _amount);
    emit Withdraw(msg.sender, _pid, _amount);
  }

  // Withdraw without caring about rewards. EMERGENCY ONLY.
  function emergencyWithdraw(uint256 _pid) public {
    PoolInfo storage pool = poolInfo[_pid];
    UserInfo storage user = userInfo[_pid][msg.sender];
    pool.lpToken.safeTransfer(address(msg.sender), user.amount);
    emit EmergencyWithdraw(msg.sender, _pid, user.amount);
    user.amount = 0;
    user.rewardDebt = 0;
  }

  // Safe rocket transfer function, just in case if rounding error causes pool to not have enough Rockets.
  function safeRocketTransfer(address _to, uint256 _amount) internal {
    uint256 rocketBal = rocket.balanceOf(address(this));
    if (_amount > rocketBal) {
      rocket.transfer(_to, rocketBal);
    } else {
      rocket.transfer(_to, _amount);
    }
  }
}
