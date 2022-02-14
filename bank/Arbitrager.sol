// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "hardhat/console.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3FlashCallback.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "../common/TowerProtocol.sol";
import "../common/EnableSwap.sol";
import "../interfaces/IBank.sol";
import "../libraries/Babylonian.sol";

contract Arbitrager is TowerProtocol, EnableSwap, IUniswapV3FlashCallback {
    using SafeERC20 for IERC20;

    IBank public bank;
    IERC20 public collat;
    IERC20 public tower;
    IERC20 public cube;
    address public profitController;
    IUniswapV2Pair public towerPair;
    IUniswapV3Pool public uniswapPool;

    uint256 private swapFee;

    uint256 private targetHighPrice;
    uint256 private targetLowPrice;

    struct FlashCallbackData {
        uint256 usdcAmt;
        bool isBuy;
    }

    event LogSetContracts(
        address bank,
        address collat,
        address tower,
        address cube,
        address profitHandler,
        address towerPair,
        address uniswapPool
    );
    event LogSetTargetBand(uint256 targetHighPrice, uint256 targetLowPrice);
    event LogSetSwapFee(uint256 swapFee);
    event LogTrade(
        uint256 initialUsdc,
        uint256 fee,
        uint256 profit,
        bool indexed isBuy
    );

    constructor(
        address _bank,
        address _collat,
        address _tower,
        address _cube,
        address _profitController,
        address _towerPair,
        address _swapController,
        address _uniswapPool
    ) {
        setContracts(
            _bank,
            _collat,
            _tower,
            _cube,
            _profitController,
            _towerPair,
            _uniswapPool
        );
        uint256 _highBand = (PRICE_PRECISION * 45) / 10000; // 0.45%
        uint256 _lowBand = (PRICE_PRECISION * 40) / 10000; // 0.4%
        setTargetBand(_lowBand, _highBand);
        setSwapFee((SWAP_FEE_PRECISION * 2) / 1000); // 0.2%

        setSwapController(_swapController);
    }

    function setContracts(
        address _bank,
        address _collat,
        address _tower,
        address _cube,
        address _profitController,
        address _towerPair,
        address _uniswapPool
    ) public onlyOwner {
        bank = _bank != address(0) ? IBank(_bank) : bank;
        collat = _collat != address(0) ? IERC20(_collat) : collat;
        tower = _tower != address(0) ? IERC20(_tower) : tower;
        cube = _cube != address(0) ? IERC20(_cube) : cube;
        profitController = _profitController != address(0)
            ? _profitController
            : profitController;
        towerPair = _towerPair != address(0)
            ? IUniswapV2Pair(_towerPair)
            : towerPair;
        uniswapPool = _uniswapPool != address(0)
            ? IUniswapV3Pool(_uniswapPool)
            : uniswapPool;

        emit LogSetContracts(
            address(bank),
            address(collat),
            address(tower),
            address(cube),
            profitController,
            address(towerPair),
            address(uniswapPool)
        );
    }

    function setTargetBand(uint256 _lowBand, uint256 _highBand)
        public
        onlyOwnerOrOperator
    {
        targetHighPrice = PRICE_PRECISION + _highBand;
        targetLowPrice = PRICE_PRECISION - _lowBand;

        emit LogSetTargetBand(targetHighPrice, targetLowPrice);
    }

    function setSwapFee(uint256 _swapFee) public onlyOwnerOrOperator {
        swapFee = _swapFee;
        emit LogSetSwapFee(swapFee);
    }

    /// @param fee0 The fee from calling flash for token0
    /// @param fee1 The fee from calling flash for token1
    /// @param data The data needed in the callback passed as FlashCallbackData from `initFlash`
    /// @notice implements the callback called from flash
    /// @dev fails if the flash is not profitable, meaning the amountOut from the flash is less than the amount borrowed
    function uniswapV3FlashCallback(
        uint256 fee0,
        uint256 fee1,
        bytes calldata data
    ) external override {
        require(
            msg.sender == address(uniswapPool),
            "Arbitrager: sender not pool"
        );
        require(fee1 == 0, "Arbitrager: unexpected fee");

        FlashCallbackData memory decoded = abi.decode(
            data,
            (FlashCallbackData)
        );

        if (decoded.isBuy) {
            // Buy Tower
            _buyTower(decoded.usdcAmt);
        } else {
            // Sell Tower
            _sellTower(decoded.usdcAmt);
        }

        // Assert profit
        uint256 _usdcOwed = decoded.usdcAmt + fee0;
        uint256 _balanceAfter = collat.balanceOf(address(this));
        require(_balanceAfter > _usdcOwed, "Arbitrager: Minus profit");

        uint256 _profit = _balanceAfter - _usdcOwed;

        // Repay
        collat.safeTransfer(address(uniswapPool), _usdcOwed);

        // Send profit to Profit Handler
        collat.safeTransfer(profitController, _profit);

        emit LogTrade(decoded.usdcAmt, fee0, _profit, decoded.isBuy);
    }

    function buyTower() external onlyOwnerOrOperator {
        uint256 _rsvTower = 0;
        uint256 _rsvUsdc = 0;
        if (address(tower) <= address(collat)) {
            (_rsvTower, _rsvUsdc, ) = towerPair.getReserves();
        } else {
            (_rsvUsdc, _rsvTower, ) = towerPair.getReserves();
        }

        uint256 _usdcAmt = _calcUsdcAmtToBuy(_rsvUsdc, _rsvTower);
        _usdcAmt =
            (_usdcAmt * SWAP_FEE_PRECISION) /
            (SWAP_FEE_PRECISION - swapFee);

        uniswapPool.flash(
            address(this),
            _usdcAmt,
            0,
            abi.encode(FlashCallbackData({usdcAmt: _usdcAmt, isBuy: true}))
        );
    }

    function _buyTower(uint256 _usdcAmt) internal {
        // buy Tower
        collat.safeApprove(address(swapController), 0);
        collat.safeApprove(address(swapController), _usdcAmt);
        swapController.swapUsdcToTower(_usdcAmt, 0);

        // redeem Tower
        uint256 _towerAmount = tower.balanceOf(address(this));
        tower.safeApprove(address(bank), 0);
        tower.safeApprove(address(bank), _towerAmount);
        bank.arbRedeem(_towerAmount);

        // sell Cube
        uint256 _cubeAmount = cube.balanceOf(address(this));
        if (_cubeAmount > 0) {
            cube.safeApprove(address(swapController), 0);
            cube.safeApprove(address(swapController), _cubeAmount);
            swapController.swapCubeToUsdc(_cubeAmount, 0);
        }
    }

    function _calcUsdcAmtToBuy(uint256 _rsvUsdc, uint256 _rsvTower)
        internal
        view
        returns (uint256)
    {
        // Buying Tower means we want to increase the Tower price to targetLowPrice
        uint256 _y = ((targetLowPrice * _rsvUsdc * _rsvTower) /
            TOWER_PRECISION);

        return Babylonian.sqrt(_y) - _rsvUsdc;
    }

    function sellTower() external onlyOwnerOrOperator {
        uint256 _rsvTower = 0;
        uint256 _rsvUsdc = 0;
        if (address(tower) <= address(collat)) {
            (_rsvTower, _rsvUsdc, ) = towerPair.getReserves();
        } else {
            (_rsvUsdc, _rsvTower, ) = towerPair.getReserves();
        }

        uint256 _towerAmt = _calcTowerAmtToSell(_rsvUsdc, _rsvTower);
        uint256 _usdcAmt = (_towerAmt * SWAP_FEE_PRECISION) /
            (SWAP_FEE_PRECISION - swapFee) /
            MISSING_PRECISION;

        uniswapPool.flash(
            address(this),
            _usdcAmt,
            0,
            abi.encode(FlashCallbackData({usdcAmt: _usdcAmt, isBuy: false}))
        );
    }

    function _sellTower(uint256 _usdcAmt) internal {
        // mint Tower to sell
        collat.safeApprove(address(bank), 0);
        collat.safeApprove(address(bank), _usdcAmt);
        bank.arbMint(_usdcAmt);

        // sell Tower for USDC
        uint256 _towerAmt = tower.balanceOf(address(this));
        tower.safeApprove(address(swapController), 0);
        tower.safeApprove(address(swapController), _towerAmt);
        swapController.swapTowerToUsdc(_towerAmt, 0);
    }

    function _calcTowerAmtToSell(uint256 _rsvUsdc, uint256 _rsvTower)
        internal
        view
        returns (uint256)
    {
        // Selling Tower means we want to decrease the Tower price to targetHighPrice
        uint256 _y = ((_rsvTower * _rsvUsdc * targetHighPrice) *
            TOWER_PRECISION) /
            PRICE_PRECISION /
            PRICE_PRECISION;

        uint256 _result = ((Babylonian.sqrt(_y) * PRICE_PRECISION) /
            targetHighPrice) - _rsvTower;

        return _result;
    }
}
