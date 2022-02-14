// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../interfaces/ISwapController.sol";
import "../interfaces/IFirebirdZap.sol";
import "../interfaces/IFirebirdRouter.sol";
import "../interfaces/IFirebirdFormula.sol";
import "../interfaces/IFirebirdFactory.sol";
import "./TowerProtocol.sol";

contract SwapController is ISwapController, TowerProtocol {
    using SafeERC20 for IERC20;

    uint256 private constant TIMEOUT = 300;

    IFirebirdZap private fbZap;
    IFirebirdRouter private fbRouter;
    IFirebirdFactory private fbFactory;
    IUniswapV2Pair private fbCubePair;
    IUniswapV2Pair private fbTowerPair;

    IERC20 public cube;
    IERC20 public tower;
    IERC20 public usdc;
    IERC20 public wmatic;

    address[] private fbCubePairPath;
    address[] private fbTowerPairPath;
    address[] private fbWMaticPairPath;

    uint8[] private fbDexIdsFB;
    uint8[] private fbDexIdsQuick;

    event LogSetContracts(
        address fbZap,
        address fbRouter,
        address fbFactory,
        address fbCubePair,
        address fbTowerPair
    );
    event LogSetPairPaths(
        address[] fbCubePairPath,
        address[] fbTowerPairPath,
        address[] fbWMaticPairPath
    );
    event LogSetDexIds(uint8[] fbDexIdsFB, uint8[] fbDexIdsQuick);

    constructor(
        address _fbZap,
        address _fbRouter,
        address _fbFactory,
        address _fbCubePair,
        address _fbTowerPair,
        address _fbWMaticPair, // 0x6e7a5FAFcec6BB1e78bAE2A1F0B612012BF14827
        address _cube,
        address _tower,
        address _usdc, // 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174
        address _wmatic // 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270
    ) {
        require(
            _fbZap != address(0) &&
                _fbRouter != address(0) &&
                _fbFactory != address(0) &&
                _fbCubePair != address(0) &&
                _fbTowerPair != address(0) &&
                _fbWMaticPair != address(0),
            "Swap: Invalid Address"
        );

        setContracts(_fbZap, _fbRouter, _fbFactory, _fbCubePair, _fbTowerPair);

        address[] memory _fbCubePairPath = new address[](1);
        _fbCubePairPath[0] = _fbCubePair;
        address[] memory _fbTowerPairPath = new address[](1);
        _fbTowerPairPath[0] = _fbTowerPair;
        address[] memory _fbWMaticPairPath = new address[](1);
        _fbWMaticPairPath[0] = _fbWMaticPair;
        setPairPaths(_fbCubePairPath, _fbTowerPairPath, _fbWMaticPairPath);

        uint8[] memory _fbDexIdsFB = new uint8[](1);
        _fbDexIdsFB[0] = 0;
        uint8[] memory _fbDexIdsQuick = new uint8[](1);
        _fbDexIdsQuick[0] = 1;
        setDexIds(_fbDexIdsFB, _fbDexIdsQuick);

        cube = IERC20(_cube);
        tower = IERC20(_tower);
        usdc = IERC20(_usdc);
        wmatic = IERC20(_wmatic);
    }

    // Swap functions
    function swapUsdcToTower(uint256 _amount, uint256 _minOut)
        external
        override
        nonReentrant
    {
        usdc.safeTransferFrom(msg.sender, address(this), _amount);
        usdc.safeApprove(address(fbRouter), 0);
        usdc.safeApprove(address(fbRouter), _amount);

        fbRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            address(usdc),
            address(tower),
            _amount,
            _minOut,
            fbTowerPairPath,
            fbDexIdsFB,
            msg.sender,
            block.timestamp + TIMEOUT
        );
    }

    function swapUsdcToCube(uint256 _amount, uint256 _minOut)
        external
        override
        nonReentrant
    {
        usdc.safeTransferFrom(msg.sender, address(this), _amount);
        usdc.safeApprove(address(fbRouter), 0);
        usdc.safeApprove(address(fbRouter), _amount);

        fbRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            address(usdc),
            address(cube),
            _amount,
            _minOut,
            fbCubePairPath,
            fbDexIdsFB,
            msg.sender,
            block.timestamp + TIMEOUT
        );
    }

    function swapCubeToUsdc(uint256 _amount, uint256 _minOut)
        external
        override
        nonReentrant
    {
        cube.safeTransferFrom(msg.sender, address(this), _amount);
        cube.safeApprove(address(fbRouter), 0);
        cube.safeApprove(address(fbRouter), _amount);

        fbRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            address(cube),
            address(usdc),
            _amount,
            _minOut,
            fbCubePairPath,
            fbDexIdsFB,
            msg.sender,
            block.timestamp + TIMEOUT
        );
    }

    function swapTowerToUsdc(uint256 _amount, uint256 _minOut)
        external
        override
        nonReentrant
    {
        tower.safeTransferFrom(msg.sender, address(this), _amount);
        tower.safeApprove(address(fbRouter), 0);
        tower.safeApprove(address(fbRouter), _amount);

        fbRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            address(tower),
            address(usdc),
            _amount,
            _minOut,
            fbTowerPairPath,
            fbDexIdsFB,
            msg.sender,
            block.timestamp + TIMEOUT
        );
    }

    function swapWMaticToUsdc(uint256 _amount, uint256 _minOut)
        external
        override
        nonReentrant
    {
        wmatic.safeTransferFrom(msg.sender, address(this), _amount);
        wmatic.safeApprove(address(fbRouter), 0);
        wmatic.safeApprove(address(fbRouter), _amount);

        fbRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            address(wmatic),
            address(usdc),
            _amount,
            _minOut,
            fbWMaticPairPath,
            fbDexIdsQuick,
            msg.sender,
            block.timestamp + TIMEOUT
        );
    }

    function zapInCube(
        uint256 _amount,
        uint256 _minUsdc,
        uint256 _minLp
    ) external override nonReentrant returns (uint256) {
        cube.safeTransferFrom(msg.sender, address(this), _amount);
        cube.safeApprove(address(fbZap), 0);
        cube.safeApprove(address(fbZap), _amount);

        uint256[] memory _amounts = new uint256[](3);
        _amounts[0] = _amount; // amount_from (CUBE)
        _amounts[1] = _minUsdc; // minTokenB (USDC)
        _amounts[2] = _minLp; // minLp

        uint256 _lpAmount = fbZap.zapInToken(
            address(cube),
            _amounts,
            address(fbCubePair),
            fbDexIdsFB[0],
            address(fbRouter),
            true
        );

        require(_lpAmount > 0, "Swap: No lp");
        require(
            fbCubePair.transfer(msg.sender, _lpAmount),
            "Swap: Faild to transfer"
        );
        return _lpAmount;
    }

    function zapInUsdc(
        uint256 _amount,
        uint256 _minCube,
        uint256 _minLp
    ) external override nonReentrant returns (uint256) {
        usdc.safeTransferFrom(msg.sender, address(this), _amount);
        usdc.safeApprove(address(fbZap), 0);
        usdc.safeApprove(address(fbZap), _amount);

        uint256[] memory _amounts = new uint256[](3);
        _amounts[0] = _amount; // amount_from (USDC)
        _amounts[1] = _minCube; // minTokenB (CUBE)
        _amounts[2] = _minLp; // minLp

        uint256 _lpAmount = fbZap.zapInToken(
            address(usdc),
            _amounts,
            address(fbCubePair),
            fbDexIdsFB[0],
            address(fbRouter),
            true
        );

        require(_lpAmount > 0, "Swap: No lp");
        require(
            fbCubePair.transfer(msg.sender, _lpAmount),
            "Swap: Faild to transfer"
        );

        return _lpAmount;
    }

    function zapOutCube(uint256 _amount, uint256 _minOut)
        external
        override
        nonReentrant
        returns (uint256)
    {
        require(
            fbCubePair.transferFrom(msg.sender, address(this), _amount),
            "Swap: Failed to transfer pair"
        );

        require(fbCubePair.approve(address(fbZap), 0), "Swap: Approve");
        require(fbCubePair.approve(address(fbZap), _amount), "Swap: Approve");

        uint256 _cubeAmount = fbZap.zapOut(
            address(fbCubePair),
            _amount,
            address(cube),
            _minOut,
            fbDexIdsFB[0],
            address(fbRouter)
        );

        require(_cubeAmount > 0, "Swap: Cube amount is 0");
        cube.safeTransfer(msg.sender, _cubeAmount);
        return _cubeAmount;
    }

    // Setters
    function setContracts(
        address _fbZap,
        address _fbRouter,
        address _fbFactory,
        address _fbCubePair,
        address _fbTowerPair
    ) public onlyOwner {
        if (_fbZap != address(0)) {
            fbZap = IFirebirdZap(_fbZap);
        }
        if (_fbRouter != address(0)) {
            fbRouter = IFirebirdRouter(_fbRouter);
        }
        if (_fbFactory != address(0)) {
            fbFactory = IFirebirdFactory(_fbFactory);
        }
        if (_fbCubePair != address(0)) {
            fbCubePair = IUniswapV2Pair(_fbCubePair);
        }
        if (_fbTowerPair != address(0)) {
            fbTowerPair = IUniswapV2Pair(_fbTowerPair);
        }

        emit LogSetContracts(
            _fbZap,
            _fbRouter,
            _fbFactory,
            _fbCubePair,
            _fbTowerPair
        );
    }

    function setPairPaths(
        address[] memory _fbCubePairPath,
        address[] memory _fbTowerPairPath,
        address[] memory _fbWMaticPairPath
    ) public onlyOwner {
        fbCubePairPath = _fbCubePairPath;
        fbTowerPairPath = _fbTowerPairPath;
        fbWMaticPairPath = _fbWMaticPairPath;

        emit LogSetPairPaths(fbCubePairPath, fbTowerPairPath, fbWMaticPairPath);
    }

    function setDexIds(
        uint8[] memory _fbDexIdsFB,
        uint8[] memory _fbDexIdsQuick
    ) public onlyOwner {
        fbDexIdsFB = _fbDexIdsFB;
        fbDexIdsQuick = _fbDexIdsQuick;

        emit LogSetDexIds(fbDexIdsFB, fbDexIdsQuick);
    }
}
