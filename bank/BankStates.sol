// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "../common/TowerProtocol.sol";

contract BankStates is TowerProtocol {
    event LogEnableEcr(bool isEnabled);
    event LogToggleUpdatePaused(bool isPaused);

    event LogSetPriceBand(uint256 priceBand);
    event LogSetTcrMovement(uint256 tcrMovement);

    event LogSetUpdatePeriod(uint32 updatePeriod);

    event LogSetTcrMin(uint256 tcrMin);
    event LogSetEcrMin(uint256 ecrMin);

    event LogToggleMintPaused(bool isPaused);
    event LogToggleRedeemPaused(bool isPaused);
    event LogToggleZapMintPaused(bool isPaused);

    event LogSetMintFee(uint256 mintFee);
    event LogSetRedeemFee(uint256 redeemFee);

    event LogSetZapSlippage(uint256 zapSlippage);
    event LogSetSwapFee(uint256 swapFee);

    // Tcr related
    uint256 internal constant TCR_MAX = RATIO_PRECISION;
    uint256 internal constant ECR_MAX = RATIO_PRECISION;
    uint256 internal constant TARGET_PRICE = PRICE_PRECISION;

    bool public enableEcr = true;
    bool public updatePaused = false;

    uint256 public priceBand = (PRICE_PRECISION * 4) / 1000; // $0.004
    uint256 public tcrMovement = (RATIO_PRECISION * 25) / 10000; // 0.25%

    uint32 public updatePeriod = 3600;
    uint64 public blockTimestampLast;

    uint256 public tcrMin = (RATIO_PRECISION * 80) / 100; // 80%
    uint256 public ecrMin = (RATIO_PRECISION * 80) / 100; // 80%

    // Mint related
    bool public mintPaused = false;
    bool public redeemPaused = false;
    bool public zapMintPaused = false;

    uint256 public mintFee = (RATIO_PRECISION * 3) / 1000; // 0.3%
    uint256 public redeemFee = (RATIO_PRECISION * 4) / 1000; // 0.4%

    uint256 public zapSlippage = (RATIO_PRECISION * 3) / 100; // 3%
    uint256 internal constant LIMIT_SWAP_TIME = 10 minutes;
    uint256 internal swapFee = (SWAP_FEE_PRECISION * 2) / 1000; // 0.2%

    function toggleEnableEcr() external onlyOwnerOrOperator {
        enableEcr = !enableEcr;
        emit LogEnableEcr(enableEcr);
    }

    function toggleUpdatePaused() external onlyOwnerOrOperator {
        updatePaused = !updatePaused;
        emit LogToggleUpdatePaused(updatePaused);
    }

    function setPriceBand(uint256 _priceBand) external onlyOwnerOrOperator {
        priceBand = _priceBand;
        emit LogSetPriceBand(priceBand);
    }

    function setTcrMovement(uint256 _tcrMovement) external onlyOwnerOrOperator {
        tcrMovement = _tcrMovement;
        emit LogSetTcrMovement(tcrMovement);
    }

    function setUpdatePeriod(uint32 _updatePeriod)
        external
        onlyOwnerOrOperator
    {
        updatePeriod = _updatePeriod;
        emit LogSetUpdatePeriod(updatePeriod);
    }

    function setTcrMin(uint256 _tcrMin) external onlyOwnerOrOperator {
        tcrMin = _tcrMin;
        emit LogSetTcrMin(_tcrMin);
    }

    function setEcrMin(uint256 _ecrMin) external onlyOwnerOrOperator {
        ecrMin = _ecrMin;
        emit LogSetEcrMin(ecrMin);
    }

    function toggleMintPaused() external onlyOwnerOrOperator {
        mintPaused = !mintPaused;
        emit LogToggleMintPaused(mintPaused);
    }

    function toggleRedeemPaused() external onlyOwnerOrOperator {
        redeemPaused = !redeemPaused;
        emit LogToggleRedeemPaused(redeemPaused);
    }

    function toggleZapMintPaused() external onlyOwnerOrOperator {
        zapMintPaused = !zapMintPaused;
        emit LogToggleZapMintPaused(zapMintPaused);
    }

    function setMintFee(uint256 _mintFee) external onlyOwner {
        mintFee = _mintFee;
        emit LogSetMintFee(mintFee);
    }

    function setRedeemFee(uint256 _redeemFee) external onlyOwner {
        redeemFee = _redeemFee;
        emit LogSetRedeemFee(redeemFee);
    }

    function setZapSlippage(uint256 _zapSlippage) external onlyOwnerOrOperator {
        zapSlippage = _zapSlippage;
        emit LogSetZapSlippage(zapSlippage);
    }

    function setSwapFee(uint256 _swapFee) external onlyOwner {
        swapFee = _swapFee;
        emit LogSetSwapFee(swapFee);
    }
}
