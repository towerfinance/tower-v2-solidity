// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

interface ITwapOracle {
    function consult(uint256 amountIn) external view returns (uint256);
}