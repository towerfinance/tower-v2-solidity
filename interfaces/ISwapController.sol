// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

interface ISwapController {
    function swapUsdcToTower(uint256 _amount, uint256 _minOut) external;

    function swapUsdcToCube(uint256 _amount, uint256 _minOut) external;

    function swapCubeToUsdc(uint256 _amount, uint256 _minOut) external;

    function swapTowerToUsdc(uint256 _amount, uint256 _minOut) external;

    function zapInCube(
        uint256 _amount,
        uint256 _minUsdc,
        uint256 _minLp
    ) external returns (uint256);

    function zapInUsdc(
        uint256 _amount,
        uint256 _minCube,
        uint256 _minLp
    ) external returns (uint256);

    function zapOutCube(uint256 _amount, uint256 _minOut)
        external
        returns (uint256);

    function swapWMaticToUsdc(uint256 _amount, uint256 _minOut) external;
}
