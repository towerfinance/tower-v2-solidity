// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.4;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "../interfaces/IProfitController.sol";
import "../interfaces/ICubeStake.sol";
import "../interfaces/ITowerERC20.sol";
import "../common/TowerProtocol.sol";
import "../common/EnableSwap.sol";

import "../interfaces/IUniswapV2Router.sol";
import "../interfaces/IFirebirdRouter.sol";

contract ProfitController is
    IProfitController,
    TowerProtocol,
    Initializable,
    EnableSwap
{
    using SafeERC20 for ITowerERC20;
    using SafeERC20 for IERC20;

    ITowerERC20 public cube;
    ITowerERC20 public tower;
    IERC20 public wmatic;
    IERC20 public usdc;
    ICubeStake public cubeStake;

    uint256 public burnRate;

    event LogConvert(
        uint256 cubeFromFarm,
        uint256 usdcFromArb,
        uint256 cubeFromArb,
        uint256 towerFromFee,
        uint256 usdcFromFee,
        uint256 cubeFromFee,
        uint256 wmaticFromInvest,
        uint256 usdcFromInvest,
        uint256 cubeFromInvest,
        uint256 totalCube
    );
    event LogDistributeStake(uint256 distributeAmount, uint256 burnAmount);
    event LogSetCubeStake(address cubeStake);
    event LogSetBurnRate(uint256 burnRate);

    function init(
        address _cube,
        address _tower,
        address _cubeStake,
        address _swapController
    ) external initializer onlyOwner {
        cube = ITowerERC20(_cube);
        tower = ITowerERC20(_tower);
        cubeStake = ICubeStake(_cubeStake);
        wmatic = IERC20(ADDRESS_WMATIC);
        usdc = IERC20(ADDRESS_USDC);

        setSwapController(_swapController);
        setBurnRate((RATIO_PRECISION * 20) / 100); // 20%
    }

    function convert() external onlyOwnerOrOperator nonReentrant {
        // InitialCube is the profit from Farm penalty
        uint256 _cubeFromFarm = cube.balanceOf(address(this));

        // InitialUsdc is the profit from Arbitrager
        uint256 _usdcFromArb = usdc.balanceOf(address(this));
        if (_usdcFromArb > 0) {
            usdc.safeApprove(address(swapController), 0);
            usdc.safeApprove(address(swapController), _usdcFromArb);
            swapController.swapUsdcToCube(_usdcFromArb, 0);
        }
        uint256 _cubeAfterArb = cube.balanceOf(address(this));
        uint256 _cubeFromArb = _cubeAfterArb - _cubeFromFarm;

        // InitialTower is the profit from Bank fee
        uint256 _towerFromFee = tower.balanceOf(address(this));
        uint256 _usdcFromFee = 0;
        if (_towerFromFee > 0) {
            tower.safeApprove(address(swapController), 0);
            tower.safeApprove(address(swapController), _towerFromFee);
            swapController.swapTowerToUsdc(_towerFromFee, 0);

            _usdcFromFee = usdc.balanceOf(address(this));
            usdc.safeApprove(address(swapController), 0);
            usdc.safeApprove(address(swapController), _usdcFromFee);
            swapController.swapUsdcToCube(_usdcFromFee, 0);
        }
        uint256 _cubeAfterFee = cube.balanceOf(address(this));
        uint256 _cubeFromFee = _cubeAfterFee - _cubeAfterArb;

        // InitialWmatic is the profit from Invest
        uint256 _maticFromInvest = wmatic.balanceOf(address(this));
        uint256 _usdcFromInvest = 0;
        if (_maticFromInvest > 0) {
            wmatic.safeApprove(address(swapController), 0);
            wmatic.safeApprove(address(swapController), _maticFromInvest);
            swapController.swapWMaticToUsdc(_maticFromInvest, 0);

            _usdcFromInvest = usdc.balanceOf(address(this));
            usdc.safeApprove(address(swapController), 0);
            usdc.safeApprove(address(swapController), _usdcFromInvest);
            swapController.swapUsdcToCube(_usdcFromInvest, 0);
        }
        uint256 _cubeAfterInvest = cube.balanceOf(address(this));
        uint256 _cubeFromInvest = _cubeAfterInvest - _cubeAfterFee;

        emit LogConvert(
            _cubeFromFarm,
            _usdcFromArb,
            _cubeFromArb,
            _towerFromFee,
            _usdcFromFee,
            _cubeFromFee,
            _maticFromInvest,
            _usdcFromInvest,
            _cubeFromInvest,
            _cubeAfterInvest
        );
    }

    function distributeStake(uint256 _amount)
        external
        override
        onlyOwnerOrOperator
    {
        require(_amount > 0, "Amount must be greater than 0");

        uint256 _actualAmt = Math.min(cube.balanceOf(address(this)), _amount);
        uint256 _amtToBurn = (_actualAmt * burnRate) / RATIO_PRECISION;

        uint256 _distributeAmt = _actualAmt - _amtToBurn;
        if (_amtToBurn > 0) {
            cube.burn(address(this), _amtToBurn);
        }

        cube.safeApprove(address(cubeStake), 0);
        cube.safeApprove(address(cubeStake), _distributeAmt);
        cubeStake.distribute(_distributeAmt);

        emit LogDistributeStake(_distributeAmt, _amtToBurn);
    }

    function setCubeStake(address _cubeStake) public onlyOwner {
        require(_cubeStake != address(0), "Invalid address");
        cubeStake = ICubeStake(_cubeStake);
        emit LogSetCubeStake(_cubeStake);
    }

    function setBurnRate(uint256 _burnRate) public onlyOwnerOrOperator {
        burnRate = _burnRate;
        emit LogSetBurnRate(burnRate);
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

    function rescueFund(address _token, uint256 _amount) external onlyOwner {
        IERC20(_token).safeTransfer(owner(), _amount);
    }
}
