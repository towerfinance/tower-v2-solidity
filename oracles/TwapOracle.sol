// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "hardhat/console.sol";

import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

import "../libraries/FixedPoint.sol";
import "../common/TowerProtocol.sol";
import "../interfaces/ITwapOracle.sol";

contract TwapOracle is TowerProtocol, ITwapOracle {
    using FixedPoint for *;

    IUniswapV2Pair public immutable pair;

    uint64 public updatePeriod;

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint64 public blockTimestampLast;
    FixedPoint.uq112x112 public price0Average;
    FixedPoint.uq112x112 public price1Average;

    bool private use0;

    event PeriodUpdated(uint64 newPeriod);

    constructor(address _pairAddress, address _targetAddress) {
        IUniswapV2Pair _pair = IUniswapV2Pair(_pairAddress);
        pair = _pair;
        price0CumulativeLast = _pair.price0CumulativeLast();
        price1CumulativeLast = _pair.price1CumulativeLast();

        if (_pair.token0() == _targetAddress) {
            use0 = true;
        } else if (_pair.token1() == _targetAddress) {
            use0 = false;
        } else {
            revert("Twap: Invalid token or pair");
        }

        uint112 _resv0;
        uint112 _resv1;
        (_resv0, _resv1, blockTimestampLast) = _pair.getReserves();
        require(_resv0 != 0 && _resv1 != 0, "Twap: no reserves");
    }

    function update() public {
        (
            uint256 _price0Cumulative,
            uint256 _price1Cumulative,
            uint64 _blockTimestamp
        ) = _currentCumulativePrices();

        uint64 _timeElapsed = _blockTimestamp - blockTimestampLast; // Overflow is desired
        require(_timeElapsed >= updatePeriod, "Twap: update too soon");

        // Overflow is desired, casting never truncates
        // Cumulative price is in (uq112x112 price * seconds) units so we simply wrap it after division by time elapsed
        price0Average = FixedPoint.uq112x112(
            uint224((_price0Cumulative - price0CumulativeLast) / _timeElapsed)
        );
        price1Average = FixedPoint.uq112x112(
            uint224((_price1Cumulative - price1CumulativeLast) / _timeElapsed)
        );
        price0CumulativeLast = _price0Cumulative;
        price1CumulativeLast = _price1Cumulative;
        blockTimestampLast = _blockTimestamp;
    }

    function consult(uint256 amountIn)
        external
        view
        override
        returns (uint256)
    {
        if (use0) {
            return price0Average.mul(amountIn).decode144();
        } else {
            return price1Average.mul(amountIn).decode144();
        }
    }

    function setPeriod(uint64 _period) external onlyOwnerOrOperator {
        updatePeriod = _period;
        uint64 _blockTimestamp = _currentBlockTs();
        uint64 _timeElapsed = _blockTimestamp - blockTimestampLast; // Overflow is desired
        if (_timeElapsed >= updatePeriod) {
            update();
        }

        emit PeriodUpdated(updatePeriod);
    }

    // produces the cumulative price using counterfactuals to save gas and avoid a call to sync.
    function _currentCumulativePrices()
        internal
        view
        returns (
            uint256 price0Cumulative_,
            uint256 price1Cumulative_,
            uint64 blockTimestamp_
        )
    {
        blockTimestamp_ = _currentBlockTs();
        price0Cumulative_ = pair.price0CumulativeLast();
        price1Cumulative_ = pair.price1CumulativeLast();

        // if time has elapsed since the last update on the pair, mock the accumulated price values
        (uint112 reserve0, uint112 reserve1, uint64 _blockTimestampLast) = pair
            .getReserves();
        if (_blockTimestampLast != blockTimestamp_) {
            // subtraction overflow is desired
            uint64 timeElapsed = blockTimestamp_ - _blockTimestampLast;
            // addition overflow is desired
            // counterfactual
            price0Cumulative_ +=
                uint256(FixedPoint.fraction(reserve1, reserve0)._x) *
                timeElapsed;
            // counterfactual
            price1Cumulative_ +=
                uint256(FixedPoint.fraction(reserve0, reserve1)._x) *
                timeElapsed;
        }
    }
}
