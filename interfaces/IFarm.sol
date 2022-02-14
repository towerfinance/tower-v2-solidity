// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

interface IFarm {
    function deposit(
        uint256 pid,
        uint256 amount,
        address to
    ) external;

    function harvest(uint256 pid) external;

    function claim(uint256 pid, uint256 vid) external;

    function claimWithPenalty(uint256 pid, uint256 vid) external;

    function withdrawAndHarvest(uint256 pid, uint256 amount) external;

    function getLpToken(uint256 pid) external returns (address);
}
