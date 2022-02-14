// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import "../interfaces/IPriceOracle.sol";
import "../common/TowerProtocol.sol";
import "./TwapOracle.sol";

contract PriceOracle is TowerProtocol, IPriceOracle {
    AggregatorV3Interface public immutable chainlinkCollatUsd;
    TwapOracle public towerCollatTwapOracle;
    TwapOracle public cubeCollatTwapOracle;

    event TowerOracleUpdated(address indexed newOracle);
    event CubeOracleUpdated(address indexed newOracle);

    constructor(
        address _chainlinkCollatUsd,
        address _towerCollatTwapOracle,
        address _cubeCollatTwapOracle
    ) {
        chainlinkCollatUsd = AggregatorV3Interface(_chainlinkCollatUsd);
        setTowerOracle(_towerCollatTwapOracle);
        setCubeOracle(_cubeCollatTwapOracle);
    }

    function collatPrice() public view override returns (uint256) {
        (, int256 _price, , , ) = chainlinkCollatUsd.latestRoundData();
        uint8 _decimals = chainlinkCollatUsd.decimals();
        require(_price > 0, "Oracle: invalid collat price");

        return (uint256(_price) * PRICE_PRECISION) / (10**_decimals);
    }

    function towerPrice() external view override returns (uint256) {
        uint256 _collatPrice = collatPrice();
        uint256 _towerPrice = towerCollatTwapOracle.consult(TOWER_PRECISION);
        require(_towerPrice > 0, "Oracle: invalid tower price");

        return (_collatPrice * _towerPrice) / PRICE_PRECISION;
    }

    function cubePrice() external view override returns (uint256) {
        uint256 _collatPrice = collatPrice();
        uint256 _cubePrice = cubeCollatTwapOracle.consult(CUBE_PRECISION);
        require(_cubePrice > 0, "Oracle: invalid cube price");

        return (_collatPrice * _cubePrice) / PRICE_PRECISION;
    }

    function setTowerOracle(address _oracle) public onlyOwner {
        towerCollatTwapOracle = TwapOracle(_oracle);
        emit TowerOracleUpdated(_oracle);
    }

    function setCubeOracle(address _oracle) public onlyOwner {
        cubeCollatTwapOracle = TwapOracle(_oracle);
        emit CubeOracleUpdated(_oracle);
    }
}
