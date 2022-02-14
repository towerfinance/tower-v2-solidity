// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "../common/TowerProtocol.sol";
import "../common/Farmable.sol";

contract Treasury is TowerProtocol, Farmable {
    using SafeERC20 for IERC20;

    function executeTransaction(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data
    ) public onlyOwner returns (bytes memory) {
        bytes memory callData;

        if (bytes(signature).length == 0) {
            callData = data;
        } else {
            callData = abi.encodePacked(
                bytes4(keccak256(bytes(signature))),
                data
            );
        }
        (bool success, bytes memory returnData) = target.call{value: value}(
            callData
        );
        require(success, string("Treasury::Transaction execution reverted."));
        return returnData;
    }
}
