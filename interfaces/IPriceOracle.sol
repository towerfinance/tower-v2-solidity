// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

interface IPriceOracle {
    function collatPrice() external view returns (uint256);

    function towerPrice() external view returns (uint256);

    function cubePrice() external view returns (uint256);
}
