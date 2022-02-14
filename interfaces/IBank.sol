// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

interface IBank {
    function tcr() external view returns (uint256);

    function ecr() external view returns (uint256);

    function arbMint(uint256 _collatIn) external;

    function arbRedeem(uint256 _towerIn) external;

    function unclaimedCollat() external view returns (uint256);
}
