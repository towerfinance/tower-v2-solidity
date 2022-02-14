// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "../interfaces/ISwapController.sol";

abstract contract EnableSwap is Ownable, Initializable {
    ISwapController public swapController;

    event LogSetSwapController(address indexed swapController);

    function setSwapController(address _swapController) public onlyOwner {
        require(_swapController != address(0), "EnableSwap: invalid address");
        swapController = ISwapController(_swapController);
        emit LogSetSwapController(_swapController);
    }
}
