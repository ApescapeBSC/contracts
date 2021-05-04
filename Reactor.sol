// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import '@openzeppelin/contracts/utils/Address.sol';

import './utils/MathUtils.sol';

import './interfaces/IPancakeFactory.sol';
import './interfaces/IPancakePair.sol';
import './interfaces/IPancakeRouter.sol';
import './interfaces/IPancakeStakeContract.sol';
import './interfaces/IWBNB.sol';

import './MasterChefBnb.sol';
import './NitroToken.sol';
import './ChadToken.sol';

/*
██████╗ ██████╗ ██╗  ██╗ ██████╗████████╗ ██████╗ ██████╗
██╔══██╗╚════██╗██║  ██║██╔════╝╚══██╔══╝██╔═████╗██╔══██╗
██████╔╝ █████╔╝███████║██║        ██║   ██║██╔██║██████╔╝
██╔══██╗ ╚═══██╗╚════██║██║        ██║   ████╔╝██║██╔══██╗
██║  ██║██████╔╝     ██║╚██████╗   ██║   ╚██████╔╝██║  ██║
╚═╝  ╚═╝╚═════╝      ╚═╝ ╚═════╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝
*/

contract Reactor is ReentrancyGuard {
  using SafeMath for uint256;
  using MathUtils for uint256;
  using SafeERC20 for IERC20;

  event TokensBought(address indexed from, uint256 amountInvested, uint256 tokensMinted);
  event TokensSold(address indexed from, uint256 tokensSold, uint256 amountReceived);
  event TokensBurned(uint256 amount);
  event RewardsDistributed(uint256 reserveAmount);

  /// @notice A 10% tax is applied to every purchase or sale of tokens.
  uint256 public constant TAX = 10;

  /// @notice The slope of the bonding curve.
  uint256 public constant DIVIDER = 1000000; // 1 / multiplier 0.000001 (so that we don't deal with decimals)

  address constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

  address public governance;

  address public rocket;

  address public factory = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;

  address public router = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

  address public stakingContract = 0x73feaa1eE314F8c655E354234017bE2193C9E24E;

  address public wbnb = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

  address public cake = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;

  // BNB/CAKE LP
  address public reserve = 0x0eD7e52944161450477ee417DE9Cd3a859b14fD0;

  /// @notice Nitro token instance.
  NitroToken public token;

  ChadToken public chad;

  /// @notice Total reserve value that backs all tokens in circulation.
  /// @dev Area below the bonding curve.
  uint256 public totalReserve;

  /// @notice Total rewards that have been distributed to stakers.
  uint256 public totalRewardsDistributed;

  uint256 public startTime;

  // Migration settings
  bool public migrationInitiated;
  uint256 public migrationDelay = 1 weeks;
  uint256 public migrationTime;
  address public migrationTarget;

  // Pamp settings
  uint256 public percentageOfApe = 10000; // 0.01%
  uint256 public pampInterval = 60 minutes;
  uint256 public lastPamp;

  // Chad minting settings
  uint256 public chadPerBnb = 0.002 ether;
  uint256 public chadMaxSupply = 10000000 ether;
  bool public chadSupplyReached;

  // Stake pool of bnb/cake rewards for Pancakeswap stake
  uint256 private stakePool = 251;

  MasterChefBnb public masterChefBnb;

  modifier initiated() {
    require(block.timestamp >= startTime, 'RocketMoon: Contract not yet open for deposits');
    _;
  }

  modifier onlyGovernance() {
    require(msg.sender == governance, 'RocketMoon: Caller must be governance');
    _;
  }

  constructor(
    uint256 _startTime,
    address _masterChefBnb,
    address _rocket,
    address _chad,
    address _governance
  ) public {
    masterChefBnb = MasterChefBnb(_masterChefBnb);
    rocket = _rocket;
    chad = ChadToken(_chad);
    governance = _governance;
    token = new NitroToken(address(this));
    startTime = _startTime == 0 || _startTime < block.timestamp ? block.timestamp : _startTime;
    _approveMax(reserve, address(masterChefBnb), 0);
  }

  receive() external payable {}

  /// @notice Exchanges reserve to tokens according to the bonding curve formula.
  /// @dev Amount to be invested needs to be approved first.
  function invest() external payable initiated nonReentrant {
    IWBNB(wbnb).deposit{ value: msg.value }();
    _invest(msg.sender, msg.value);

    if (chadSupplyReached) {
      return;
    } else {
      uint256 chadToMint = chadPerBnb.mul(msg.value).div(1e18);
      if (chad.totalSupply().add(chadToMint) > chadMaxSupply) {
        chadToMint = chadMaxSupply.sub(chadToMint);
        chadSupplyReached = true;
      }
      chad.mint(msg.sender, chadToMint);
    }
  }

  /// @notice Exchanges token for reserve according to the bonding curve formula.
  /// @param tokenAmount Token value in wei that will be exchanged to reserve
  function sell(uint256 tokenAmount) external nonReentrant {
    _sell(msg.sender, tokenAmount);
  }

  function buyAndBurn() public {
    _buyAndBurn();
  }

  function harvestAndDistributeRewards() external {
    uint256 harvested = _harvest();
    if (harvested != 0) {
      _distributeRewards(harvested);
    }
  }

  /// @notice Starts the process of migration
  function initiateMigration(address target) external onlyGovernance {
    migrationInitiated = true;
    migrationTime = block.timestamp.add(migrationDelay);
    migrationTarget = target;
  }

  /// @notice Allows governance to cancel migration
  function cancelMigration() external onlyGovernance {
    migrationInitiated = false;
  }

  /// @notice Migrates underlying assets to new contract
  function migrate() external {
    require(migrationInitiated, 'Rocket: Must first initiate migration');
    require(block.timestamp > migrationTime, 'Rocket: Must wait until migration time is reached');
    (uint256 totalStaked, ) =
      IPancakeStakeContract(stakingContract).userInfo(stakePool, address(this));
    IPancakeStakeContract(stakingContract).withdraw(stakePool, totalStaked);
    IERC20(reserve).safeTransfer(migrationTarget, totalStaked);
  }

  /// @notice Sets the percentage of APE in the APE/BNB liquidity pool that
  /// will be used as the maximum amount to sell rocket.
  function setPercentageOfApeToSell(uint256 amount) external onlyGovernance {
    require(amount != 0 && amount <= 10000, 'Rocket: Value not in range');
    percentageOfApe = amount;
  }

  /// @notice Total supply of tokens. This includes burned tokens.
  /// @return Total supply of token in wei.
  function getTotalSupply() public view returns (uint256) {
    return token.totalSupply();
  }

  /// @notice Total tokens that have been burned.
  /// @dev These tokens are still in circulation therefore they
  /// are still considered on the bonding curve formula.
  /// @return Total burned token amount in wei.
  function getBurnedTokensAmount() public view returns (uint256) {
    return token.balanceOf(BURN_ADDRESS);
  }

  /// @notice Token's price in wei according to the bonding curve formula.
  /// @return Current token price in BNB (wei).
  function getCurrentTokenPrice() external view returns (uint256) {
    // price = supply * multiplier
    uint256 tokenCurrentPrice = getTotalSupply().roundedDiv(DIVIDER);
    return _reservePriceInBnb().mul(tokenCurrentPrice).div(1e18);
  }

  /// @notice Calculates the amount of tokens in exchange for BNB after applying the 10% tax.
  /// @param amount BNB value in wei to use in the conversion.
  /// @return Token amount in wei after the 10% tax has been applied.
  function getBnbToTokens(uint256 amount) external view returns (uint256) {
    if (amount == 0) {
      return 0;
    }
    uint256 fee = amount.div(TAX);
    uint256 net = amount.sub(fee);
    uint256 reserveAmount = _estimateReserveGivenBnbAmount(net);
    uint256 totalTokens = getReserveToTokens(reserveAmount);
    return totalTokens;
  }

  /// @notice Calculates the amount of bnb in exchange for tokens after applying the 10% tax.
  /// @param tokenAmount Token value in wei to use in the conversion.
  /// @return Reserve amount in wei after the 10% tax has been applied.
  function getTokensToBnb(uint256 tokenAmount) external view returns (uint256) {
    if (tokenAmount == 0) {
      return 0;
    }
    uint256 reserveAmount = getTokensToReserve(tokenAmount);
    uint256 total = _reservePriceInBnb().mul(reserveAmount).div(1e18);
    uint256 fee = total.div(TAX);
    return total.sub(fee);
  }

  /// @notice Calculates the amount of tokens in exchange for reserve.
  /// @param reserveAmount Reserve value in wei to use in the conversion.
  /// @return Token amount in wei.
  function getReserveToTokens(uint256 reserveAmount) public view returns (uint256) {
    return _calculateReserveToTokens(reserveAmount, totalReserve, getTotalSupply());
  }

  /// @notice Calculates the amount of reserve in exchange for tokens.
  /// @param tokenAmount Token value in wei to use in the conversion.
  /// @return Reserve amount in wei.
  function getTokensToReserve(uint256 tokenAmount) public view returns (uint256) {
    return _calculateTokensToReserve(tokenAmount, getTotalSupply(), totalReserve);
  }

  /// @notice Worker function that exchanges reserve to tokens.
  /// Extracts 10% fee from the reserve supplied and exchanges the rest to tokens.
  /// Total amount is then sent to the lending protocol so it can start earning interest.
  /// @dev User must approve the reserve to be spent before investing.
  /// @param _amount Total reserve value in wei to be exchanged to tokens.
  function _invest(address _account, uint256 _amount) internal {
    uint256 fee = _amount.div(TAX);
    require(fee != 0, 'Transaction amount not sufficient to pay fee');

    uint256 net = _amount.sub(fee);

    uint256 liquidity = _addLiquidity(wbnb, cake, net);

    uint256 totalTokens = getReserveToTokens(liquidity);

    totalReserve = totalReserve.add(liquidity);

    // Staking automatically fetches rewards
    _stake(liquidity);

    // // Converts total cake balance to BNB for distribution
    _convertCakeBalance();
    //
    // // Distributes all bnb balance as rewards
    _distributeRewards(IERC20(wbnb).balanceOf(address(this)));

    token.mint(_account, totalTokens);
    emit TokensBought(_account, _amount, totalTokens);

    // Avoids recursive loop
    if (_account != BURN_ADDRESS) {
      _buyAndBurn();
    }
  }

  /// @notice Worker function that exchanges token for reserve.
  /// Tokens are decreased from the total supply according to the bonding curve formula.
  /// A 10% tax is applied to the reserve amount. 90% is retrieved
  /// from the lending protocol and sent to the user and 10% is used to mint and burn tokens.
  /// @param _tokenAmount Token value in wei that will be exchanged to reserve.
  function _sell(address payable _account, uint256 _tokenAmount) internal {
    require(_tokenAmount <= token.balanceOf(_account), 'Insuficcient balance');
    require(_tokenAmount > 0, 'Must sell something');

    uint256 reserveAmount = getTokensToReserve(_tokenAmount);
    IPancakeStakeContract(stakingContract).withdraw(stakePool, reserveAmount);
    _convertCakeBalance();

    (uint256 wbnbLiquidity, uint256 cakeLiquidity) = _removeLiquidity(wbnb, cake, reserveAmount);
    uint256 exchangedWbnb = _exchange(cake, wbnb, cakeLiquidity);
    uint256 totalWbnb = wbnbLiquidity.add(exchangedWbnb);
    uint256 fee = totalWbnb.div(TAX);

    require(fee >= 1, 'Must pay minimum fee');

    totalReserve = totalReserve.sub(reserveAmount);
    token.decreaseSupply(_account, _tokenAmount);

    uint256 totalClaim = totalWbnb.sub(fee);

    IWBNB(wbnb).withdraw(totalClaim);
    Address.sendValue(_account, totalClaim);
    // Distributes all bnb balance as rewards
    _distributeRewards(IERC20(wbnb).balanceOf(address(this)));

    emit TokensSold(_account, _tokenAmount, totalClaim);
  }

  function _buyAndBurn() internal {
    if (IPancakeFactory(factory).getPair(wbnb, rocket) == address(0)) {
      return;
    }

    uint256 sellAmount = _rocketSellAmount();

    // Not enough liquidity in the APE/BNB pool;
    if (sellAmount == 0) {
      return;
    }

    if (
      block.timestamp < lastPamp.add(pampInterval) || IERC20(rocket).balanceOf(address(this)) == 0
    ) {
      return;
    }

    if (IERC20(rocket).balanceOf(address(this)) < sellAmount) {
      sellAmount = IERC20(rocket).balanceOf(address(this));
    }

    uint256 convertedAmount = _exchange(rocket, wbnb, sellAmount);
    lastPamp = block.timestamp;
    _invest(BURN_ADDRESS, convertedAmount);
    emit TokensBurned(convertedAmount);
  }

  function _convertCakeBalance() internal {
    uint256 balance = IERC20(cake).balanceOf(address(this));
    if (balance != 0) {
      _exchange(cake, wbnb, balance);
    }
  }

  function _rocketSellAmount() internal view returns (uint256 _sellAmount) {
    (uint256 rocketReserve, ) = _getReserves(rocket, wbnb);
    _sellAmount = rocketReserve.div(percentageOfApe);
  }

  function _exchange(
    address tokenA,
    address tokenB,
    uint256 _inAmount
  ) internal returns (uint256 _outAmount) {
    address[] memory path = new address[](2);
    path[0] = tokenA;
    path[1] = tokenB;

    _approveMax(tokenA, router, _inAmount);

    // make the swap
    uint256[] memory amounts =
      IPancakeRouter(router).swapExactTokensForTokens(
        _inAmount,
        0, // accept any amount of pair token
        path,
        address(this),
        block.timestamp
      );

    return amounts[1];
  }

  function _addLiquidity(
    address _tokenA,
    address _tokenB,
    uint256 _AmountTokenA
  ) internal returns (uint256 _liquidity) {
    uint256 half = _AmountTokenA.div(2);
    uint256 amountTokenA = _AmountTokenA.sub(half);
    uint256 amountTokenB = _exchange(_tokenA, _tokenB, half);

    _approveMax(_tokenA, router, amountTokenA);
    _approveMax(_tokenB, router, amountTokenB);

    // add the liquidity
    (, , _liquidity) = IPancakeRouter(router).addLiquidity(
      _tokenA,
      _tokenB,
      amountTokenA,
      amountTokenB,
      0, // slippage is unavoidable
      0, // slippage is unavoidable
      address(this),
      block.timestamp
    );
  }

  function _removeLiquidity(
    address _tokenA,
    address _tokenB,
    uint256 _liquidity
  ) internal returns (uint256 _amountA, uint256 _amountB) {
    address pair = IPancakeFactory(factory).getPair(_tokenA, _tokenB);
    _approveMax(pair, router, _liquidity);

    // add the liquidity
    (_amountA, _amountB) = IPancakeRouter(router).removeLiquidity(
      _tokenA,
      _tokenB,
      _liquidity,
      0, // slippage is unavoidable
      0, // slippage is unavoidable
      address(this),
      block.timestamp
    );
  }

  function _stake(uint256 _amount) internal {
    _approveMax(reserve, stakingContract, _amount);
    IPancakeStakeContract(stakingContract).deposit(stakePool, _amount);
  }

  function _harvest() internal returns (uint256 _reward) {
    uint256 claimable =
      IPancakeStakeContract(stakingContract).pendingCake(stakePool, address(this));

    if (claimable != 0) {
      IPancakeStakeContract(stakingContract).withdraw(stakePool, 0);
      _reward = _exchange(cake, wbnb, claimable);
    }
  }

  // @dev Estimates how many LP tokens from a given amount of BNB.
  function _estimateReserveGivenBnbAmount(uint256 _amount)
    internal
    view
    returns (uint256 _liquidity)
  {
    (uint256 bnbAmount, uint256 totalSupply) = _getBnbAndSupplyAmount();
    // totalSupply.div(bnbAmount).mul(_amount);
    _liquidity = totalSupply.mul(_amount).div(bnbAmount).div(2);
  }

  function _reservePriceInBnb() internal view returns (uint256) {
    (uint256 bnbAmount, uint256 totalSupply) = _getBnbAndSupplyAmount();
    return bnbAmount.mul(2).mul(1e18).div(totalSupply);
  }

  function _getBnbAndSupplyAmount()
    internal
    view
    returns (uint256 _bnbReserve, uint256 _supplyAmount)
  {
    _supplyAmount = _getSupplyAmount(wbnb, cake);
    (_bnbReserve, ) = _getReserves(wbnb, cake);
  }

  function _getReserves(address _token0, address _token1)
    internal
    view
    returns (uint256 _reserve0, uint256 _reserve1)
  {
    address pair = IPancakeFactory(factory).getPair(_token0, _token1);
    address token0 = IPancakePair(pair).token0();
    (uint256 reserve0, uint256 reserve1, ) = IPancakePair(pair).getReserves();
    if (token0 == _token0) {
      _reserve0 = reserve0;
      _reserve1 = reserve1;
    } else {
      _reserve0 = reserve1;
      _reserve1 = reserve0;
    }
  }

  function _getSupplyAmount(address _token0, address _token1)
    internal
    view
    returns (uint256 _supplyAmount)
  {
    address pair = IPancakeFactory(factory).getPair(_token0, _token1);
    _supplyAmount = IERC20(pair).totalSupply();
  }

  function _distributeRewards(uint256 _amount) internal {
    _approveMax(wbnb, address(masterChefBnb), _amount);

    totalRewardsDistributed = totalRewardsDistributed.add(_amount);
    masterChefBnb.updateRewards(_amount);

    emit RewardsDistributed(_amount);
  }

  function _approveMax(
    address tkn,
    address spender,
    uint256 min
  ) internal {
    uint256 max = uint256(-1);
    if (IERC20(tkn).allowance(address(this), spender) <= min) {
      IERC20(tkn).safeApprove(spender, max);
    }
  }

  /**
   * Supply (s), reserve (r) and token price (p) are in a relationship defined by the bonding curve:
   *      p = m * s
   * The reserve equals to the area below the bonding curve
   *      r = s^2 / 2
   * The formula for the supply becomes
   *      s = sqrt(2 * r / m)
   *
   * In solidity computations, we are using divider instead of multiplier (because its an integer).
   * All values are decimals with 18 decimals (represented as uints), which needs to be compensated for in
   * multiplications and divisions
   */

  /// @notice Computes the increased supply given an amount of reserve.
  /// @param _reserveDelta The amount of reserve in wei to be used in the calculation.
  /// @param _totalReserve The current reserve state to be used in the calculation.
  /// @param _supply The current supply state to be used in the calculation.
  /// @return _supplyDelta token amount in wei.
  function _calculateReserveToTokens(
    uint256 _reserveDelta,
    uint256 _totalReserve,
    uint256 _supply
  ) internal pure returns (uint256 _supplyDelta) {
    uint256 _reserve = _totalReserve;
    uint256 _newReserve = _reserve.add(_reserveDelta);
    // s = sqrt(2 * r / m)
    uint256 _newSupply =
      MathUtils.sqrt(
        _newReserve
          .mul(2)
          .mul(DIVIDER) // inverse the operation (Divider instead of multiplier)
          .mul(1e18) // compensation for the squared unit
      );

    _supplyDelta = _newSupply.sub(_supply);
  }

  /// @notice Computes the decrease in reserve given an amount of tokens.
  /// @param _supplyDelta The amount of tokens in wei to be used in the calculation.
  /// @param _supply The current supply state to be used in the calculation.
  /// @param _totalReserve The current reserve state to be used in the calculation.
  /// @return _reserveDelta Reserve amount in wei.
  function _calculateTokensToReserve(
    uint256 _supplyDelta,
    uint256 _supply,
    uint256 _totalReserve
  ) internal pure returns (uint256 _reserveDelta) {
    require(_supplyDelta <= _supply, 'Token amount must be less than the supply');

    uint256 _newSupply = _supply.sub(_supplyDelta);

    uint256 _newReserve = _calculateReserveFromSupply(_newSupply);

    _reserveDelta = _totalReserve.sub(_newReserve);
  }

  /// @notice Calculates reserve given a specific supply.
  /// @param _supply The token supply in wei to be used in the calculation.
  /// @return _reserve Reserve amount in wei.
  function _calculateReserveFromSupply(uint256 _supply) internal pure returns (uint256 _reserve) {
    // r = s^2 * m / 2
    _reserve = _supply
      .mul(_supply)
      .div(DIVIDER) // inverse the operation (Divider instead of multiplier)
      .div(2)
      .roundedDiv(1e18); // correction of the squared unit
  }
}
