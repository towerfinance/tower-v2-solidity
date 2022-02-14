// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "../common/TowerProtocol.sol";
import "../common/EnableSwap.sol";
import "../common/Farmable.sol";
import "../interfaces/ITowerERC20.sol";
import "../interfaces/IFarm.sol";

contract Dustbin is TowerProtocol, EnableSwap, Farmable {
    ITowerERC20 public cube;
    IUniswapV2Pair public cubePair;

    event LogSetCube(address cube, address cubePair);
    event LogBurn(uint256 lpAmount, uint256 cubeBurnt);

    constructor(
        address _cubePair,
        address _cube,
        address _swapController
    ) {
        setCube(_cube, _cubePair);
        setSwapController(_swapController);
    }

    function burnLp(uint256 _amount) external onlyOwnerOrOperator {
        uint256 _lpBalance = cubePair.balanceOf(address(this));
        require(_lpBalance >= _amount, "Dustbin: amount > balance");

        require(
            cubePair.approve(address(swapController), 0),
            "Dustbin: failed to approve"
        );
        require(
            cubePair.approve(address(swapController), _lpBalance),
            "Dustbin: failed to approve"
        );

        uint256 _cubeAmount = swapController.zapOutCube(_amount, 0);

        cube.burn(address(this), _cubeAmount);

        emit LogBurn(_amount, _cubeAmount);
    }

    function setCube(address _cube, address _cubePair) public onlyOwner {
        require(
            _cube != address(0) && _cubePair != address(0),
            "Dustbin: invalid cube address"
        );
        cube = ITowerERC20(_cube);
        cubePair = IUniswapV2Pair(_cubePair);
        emit LogSetCube(_cube, _cubePair);
    }
}
