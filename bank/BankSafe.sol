// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../common/TowerProtocol.sol";
import "../common/OnlyBank.sol";
import "../interfaces/IBankSafe.sol";
import "../interfaces/IBank.sol";
import "../interfaces/ITowerERC20.sol";
import "../aave/IAaveLendingPool.sol";
import "../aave/IAaveIncentivesController.sol";

contract BankSafe is IBankSafe, TowerProtocol, OnlyBank {
    using SafeERC20 for IERC20;
    using SafeERC20 for ITowerERC20;

    IERC20 public collat;
    ITowerERC20 public cube;

    uint256 public override investingAmt;
    address public profitController;

    uint256 public idleCollateralUtilizationRatio; // ratio where idle collateral can be used for investment
    uint256 public constant IDLE_COLLATERAL_UTILIZATION_RATIO_MAX = 850000; // no more than 85%

    uint256 public reservedCollateralThreshold; // ratio of the threshold where collateral are reserved for redemption
    uint256 public constant RESERVE_COLLATERAL_THRESHOLD_MIN = 150000; // no less than 15%

    uint256 public override excessCollateralSafetyMargin;
    uint256 public constant EXCESS_COLLATERAL_SAFETY_MARGIN_MIN = 100000; // 10%

    ILendingPool public aaveLendingPool;
    IAaveIncentivesController public aaveIncentivesController;
    IERC20 public rewardToken;
    IERC20 public aToken;

    bool private isInvestEntered = false;

    event ProfitControllerUpdated(address indexed profitController);
    event ProfitExtracted(uint256 amount);
    event InvestDeposited(uint256 amount);
    event InvestWithdrawn(uint256 amount);
    event IncentivesClaimed(uint256 amount);
    event IdleCollateralUtilizationRatioUpdated(uint256 ratio);
    event ReservedCollateralThresholdUpdated(uint256 ratio);
    event ExcessCollateralSafetyMarginUpdated(uint256 ratio);
    event AaveLendingPoolUpdated(address lendingPool);
    event AaveIncentiveControllerUpdated(address controller);

    constructor(
        address _bank,
        address _collat,
        address _cube,
        address _profitController,
        address _aaveLendingPool,
        address _aaveIncentivesController
    ) OnlyBank(_bank) {
        collat = IERC20(_collat);
        cube = ITowerERC20(_cube);
        setProfitController(_profitController);
        setAaveLendingPool(_aaveLendingPool);
        setAaveIncentiveController(_aaveIncentivesController);

        aToken = IERC20(_getATokenAddress(_collat));
        setExcessCollateralSafetyMargin(EXCESS_COLLATERAL_SAFETY_MARGIN_MIN);
        setIdleCollateralUtilizationRatio(
            IDLE_COLLATERAL_UTILIZATION_RATIO_MAX
        );
        setReservedCollateralThreshold(RESERVE_COLLATERAL_THRESHOLD_MIN);
    }

    function transferCollatTo(address _to, uint256 _amt)
        external
        override
        onlyBank
    {
        require(_to != address(0), "Safe: invalid address");

        if (_amt > collat.balanceOf(address(this))) {
            // If low in balance, rebalance investment
            if (isInvestEntered) {
                exitInvest();
                collat.safeTransfer(_to, _amt);
                enterInvest();
            } else {
                revert("Safe: Insufficient balance");
            }
        } else {
            collat.safeTransfer(_to, _amt);
        }
    }

    function transferCubeTo(address _to, uint256 _amt)
        external
        override
        onlyBank
    {
        require(_to != address(0), "Safe: invalid address");
        cube.safeTransfer(_to, _amt);
    }

    function globalCollateralBalance() public view override returns (uint256) {
        uint256 _collateralReserveBalance = collat.balanceOf(address(this));

        return
            _collateralReserveBalance +
            investingAmt -
            IBank(bank).unclaimedCollat();
    }

    function enterInvest() public nonReentrant {
        require(
            msg.sender == address(bank) ||
                msg.sender == owner() ||
                msg.sender == operator,
            "Safe: enterInvest no auth"
        );
        require(isInvestEntered == false, "Investment already entered");

        uint256 _collateralBalance = IERC20(collat).balanceOf(address(this));

        uint256 _investmentAmount = (idleCollateralUtilizationRatio *
            _collateralBalance) / RATIO_PRECISION;

        if (_investmentAmount > 0) {
            _depositInvest(_investmentAmount);
            isInvestEntered = true;
        }
    }

    function exitInvest() public returns (uint256 profit) {
        require(
            msg.sender == address(bank) ||
                msg.sender == owner() ||
                msg.sender == operator,
            "Safe: enterInvest no auth"
        );
        profit = _withdrawInvest();
        isInvestEntered = false;
    }

    function rebalanceInvest() public {
        require(
            msg.sender == address(bank) ||
                msg.sender == owner() ||
                msg.sender == operator,
            "Safe: enterInvest no auth"
        );
        if (isInvestEntered) {
            exitInvest();
        }
        enterInvest();
    }

    function rebalanceIfUnderThreshold() external {
        require(
            msg.sender == address(bank) ||
                msg.sender == owner() ||
                msg.sender == operator,
            "Safe: enterInvest no auth"
        );
        if (!isAboveThreshold()) {
            rebalanceInvest();
        }
    }

    function _depositInvest(uint256 _amount) internal {
        require(_amount > 0, "Zero amount");
        investingAmt = _amount;
        collat.safeApprove(address(aaveLendingPool), 0);
        collat.safeApprove(address(aaveLendingPool), investingAmt);
        aaveLendingPool.deposit(
            address(collat),
            investingAmt,
            address(this),
            0
        );
        emit InvestDeposited(_amount);
    }

    function _withdrawInvest() internal nonReentrant returns (uint256) {
        uint256 newBalance = aaveLendingPool.withdraw(
            address(collat),
            balanceOfAToken(),
            address(this)
        );
        uint256 profit = 0;
        if (newBalance > investingAmt) {
            profit = newBalance - investingAmt;
        }
        investingAmt = 0;
        emit InvestWithdrawn(newBalance);
        return profit;
    }

    function extractProfit(uint256 _amount) external onlyOwnerOrOperator {
        require(_amount > 0, "Safe: Zero amount");
        require(
            profitController != address(0),
            "Safe: Invalid profitController"
        );
        uint256 _maxExcess = excessCollateralBalance();
        uint256 _maxAllowableAmount = _maxExcess -
            ((_maxExcess * excessCollateralSafetyMargin) / RATIO_PRECISION);

        uint256 _amtToTransfer = Math.min(_maxAllowableAmount, _amount);
        IERC20(collat).safeTransfer(profitController, _amtToTransfer);
        emit ProfitExtracted(_amtToTransfer);
    }

    function excessCollateralBalance() public view returns (uint256 _excess) {
        uint256 _tcr = IBank(bank).tcr();
        uint256 _ecr = IBank(bank).ecr();
        if (_ecr <= _tcr) {
            _excess = 0;
        } else {
            _excess =
                ((_ecr - _tcr) * globalCollateralBalance()) /
                RATIO_PRECISION;
        }
    }

    function _getATokenAddress(address _asset) internal view returns (address) {
        DataTypes.ReserveData memory reserveData = aaveLendingPool
            .getReserveData(_asset);
        return reserveData.aTokenAddress;
    }

    function balanceOfAToken() public view returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    function setProfitController(address _profitController) public onlyOwner {
        require(_profitController != address(0), "Invalid ProfitController");
        profitController = _profitController;
        emit ProfitControllerUpdated(_profitController);
    }

    function getUnclaimedIncentiveRewardsBalance()
        public
        view
        returns (uint256)
    {
        return aaveIncentivesController.getUserUnclaimedRewards(address(this));
    }

    function claimIncentiveRewards() public onlyOwnerOrOperator {
        uint256 _unclaimedRewards = getUnclaimedIncentiveRewardsBalance();
        address[] memory _tokens = new address[](1);
        _tokens[0] = address(aToken);
        uint256 _rewaredClaimed = aaveIncentivesController.claimRewards(
            _tokens,
            _unclaimedRewards,
            address(this)
        );

        rewardToken.safeTransfer(profitController, _rewaredClaimed);

        emit IncentivesClaimed(_rewaredClaimed);
    }

    function calcCollateralReserveRatio() public view returns (uint256) {
        uint256 _collateralReserveBalance = IERC20(collat).balanceOf(
            address(this)
        );
        uint256 _collateralBalanceWithoutInvest = _collateralReserveBalance -
            IBank(bank).unclaimedCollat();
        uint256 _globalCollateralBalance = globalCollateralBalance();
        if (_globalCollateralBalance == 0) {
            return 0;
        }
        return
            (_collateralBalanceWithoutInvest * RATIO_PRECISION) /
            _globalCollateralBalance;
    }

    function isAboveThreshold() public view returns (bool) {
        uint256 _ratio = calcCollateralReserveRatio();
        uint256 _threshold = reservedCollateralThreshold;
        return _ratio >= _threshold;
    }

    function transferTo(
        address _receiver,
        address _token,
        uint256 _amount
    ) public onlyOwner {
        IERC20 token = IERC20(_token);
        require(
            token.balanceOf(address(this)) >= _amount,
            "Not enough balance"
        );
        require(_amount > 0, "Zero amount");
        token.safeTransfer(_receiver, _amount);
    }

    function setIdleCollateralUtilizationRatio(
        uint256 _idleCollateralUtilizationRatio
    ) public onlyOwnerOrOperator {
        require(
            _idleCollateralUtilizationRatio <=
                IDLE_COLLATERAL_UTILIZATION_RATIO_MAX,
            ">idle max"
        );
        idleCollateralUtilizationRatio = _idleCollateralUtilizationRatio;
        emit IdleCollateralUtilizationRatioUpdated(
            idleCollateralUtilizationRatio
        );
    }

    function setReservedCollateralThreshold(
        uint256 _reservedCollateralThreshold
    ) public onlyOwnerOrOperator {
        require(
            _reservedCollateralThreshold >= RESERVE_COLLATERAL_THRESHOLD_MIN,
            "<threshold min"
        );
        reservedCollateralThreshold = _reservedCollateralThreshold;
        emit ReservedCollateralThresholdUpdated(reservedCollateralThreshold);
    }

    function setExcessCollateralSafetyMargin(
        uint256 _excessCollateralSafetyMargin
    ) public onlyOwnerOrOperator {
        require(
            _excessCollateralSafetyMargin >=
                EXCESS_COLLATERAL_SAFETY_MARGIN_MIN,
            "<margin min"
        );
        excessCollateralSafetyMargin = _excessCollateralSafetyMargin;
        emit ExcessCollateralSafetyMarginUpdated(excessCollateralSafetyMargin);
    }

    function setAaveLendingPool(address _aaveLendingPool) public onlyOwner {
        require(_aaveLendingPool != address(0), "Invalid address");
        aaveLendingPool = ILendingPool(_aaveLendingPool);
        emit AaveLendingPoolUpdated(_aaveLendingPool);
    }

    function setAaveIncentiveController(address _aaveIncentivesController)
        public
        onlyOwner
    {
        require(_aaveIncentivesController != address(0), "Invalid address");
        aaveIncentivesController = IAaveIncentivesController(
            _aaveIncentivesController
        );
        rewardToken = IERC20(aaveIncentivesController.REWARD_TOKEN());
        emit AaveIncentiveControllerUpdated(_aaveIncentivesController);
    }
}
