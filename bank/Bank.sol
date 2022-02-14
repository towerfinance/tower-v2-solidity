// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "hardhat/console.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

import "../interfaces/IBank.sol";
import "../interfaces/IPriceOracle.sol";
import "../interfaces/ITowerERC20.sol";
import "../interfaces/IBankSafe.sol";
import "../interfaces/IProfitController.sol";
import "../common/OnlyArbitrager.sol";
import "../common/EnableSwap.sol";
import "../libraries/Babylonian.sol";
import "./BankStates.sol";
import "./BankRecollatStates.sol";
import "./BankSafe.sol";

contract Bank is
    IBank,
    Initializable,
    BankStates,
    BankRecollatStates,
    OnlyArbitrager,
    EnableSwap
{
    using SafeERC20 for IERC20;
    using SafeERC20 for ITowerERC20;

    // Variables
    IERC20 public collat;
    ITowerERC20 public tower;
    ITowerERC20 public cube;
    IUniswapV2Pair public cubePair;
    IPriceOracle public oracle;
    IBankSafe public safe;
    IProfitController public profitController;
    address public dustbin;

    uint256 public override tcr = TCR_MAX;
    uint256 public override ecr = tcr;

    mapping(address => uint256) public redeemCubeBal;
    mapping(address => uint256) public redeemCollatBal;
    mapping(address => uint256) public lastRedeemed;
    uint256 public unclaimedCube;
    uint256 public override unclaimedCollat;

    event RatioUpdated(uint256 tcr, uint256 ecr);
    event ZapSwapped(uint256 collatAmt, uint256 lpAmount);
    event Recollateralized(uint256 collatIn, uint256 cubeOut);
    event LogMint(
        uint256 collatIn,
        uint256 cubeIn,
        uint256 towerOut,
        uint256 towerFee
    );
    event LogRedeem(
        uint256 towerIn,
        uint256 collatOut,
        uint256 cubeOut,
        uint256 towerFee
    );

    function init(
        address _collat,
        address _tower,
        address _cube,
        address _cubePair,
        address _oracle,
        address _safe,
        address _dustbin,
        address _arbitrager,
        address _profitController,
        address _swapController,
        uint256 _tcr
    ) public initializer onlyOwner {
        require(
            _collat != address(0) &&
                _tower != address(0) &&
                _cube != address(0) &&
                _oracle != address(0) &&
                _safe != address(0),
            "Bank: invalid address"
        );

        collat = IERC20(_collat);
        tower = ITowerERC20(_tower);
        cube = ITowerERC20(_cube);
        cubePair = IUniswapV2Pair(_cubePair);
        oracle = IPriceOracle(_oracle);
        safe = IBankSafe(_safe);
        dustbin = _dustbin;
        profitController = IProfitController(_profitController);
        tcr = _tcr;
        blockTimestampLast = _currentBlockTs();

        // Init for OnlyArbitrager
        setArbitrager(_arbitrager);

        setSwapController(_swapController);
    }

    function setContracts(
        address _safe,
        address _dustbin,
        address _profitController,
        address _oracle
    ) public onlyOwner {
        require(
            _safe != address(0) &&
                _dustbin != address(0) &&
                _profitController != address(0) &&
                _oracle != address(0),
            "Bank: Address zero"
        );

        safe = IBankSafe(_safe);
        dustbin = _dustbin;
        profitController = IProfitController(_profitController);
        oracle = IPriceOracle(_oracle);
    }

    // Public functions
    function calcEcr() public view returns (uint256) {
        if (!enableEcr) {
            return tcr;
        }
        uint256 _totalCollatValueE18 = (totalCollatAmt() *
            MISSING_PRECISION *
            oracle.collatPrice()) / PRICE_PRECISION;

        uint256 _ecr = (_totalCollatValueE18 * RATIO_PRECISION) /
            tower.totalSupply();
        _ecr = Math.max(_ecr, ecrMin);
        _ecr = Math.min(_ecr, ECR_MAX);

        return _ecr;
    }

    function totalCollatAmt() public view returns (uint256) {
        return
            safe.investingAmt() +
            collat.balanceOf(address(safe)) -
            unclaimedCollat;
    }

    function update() public nonReentrant {
        require(!updatePaused, "Bank: update paused");

        uint64 _timeElapsed = _currentBlockTs() - blockTimestampLast; // Overflow is desired
        require(_timeElapsed >= updatePeriod, "Bank: update too soon");

        uint256 _towerPrice = oracle.towerPrice();

        if (_towerPrice > TARGET_PRICE + priceBand) {
            tcr = Math.max(tcr - tcrMovement, tcrMin);
        } else if (_towerPrice < TARGET_PRICE - priceBand) {
            tcr = Math.min(tcr + tcrMovement, TCR_MAX);
        }

        ecr = calcEcr();
        blockTimestampLast = _currentBlockTs();
        emit RatioUpdated(tcr, ecr);
    }

    function mint(
        uint256 _collatIn,
        uint256 _cubeIn,
        uint256 _towerOutMin
    ) external onlyNonContract nonReentrant {
        require(!mintPaused, "Bank: mint paused");
        require(_collatIn > 0, "Bank: _collatIn <= 0");

        // Don't take in more collateral than the pool ceiling for this token allows
        require(
            (safe.globalCollateralBalance() + _collatIn) <= poolCeiling,
            "Bank: Pool Ceiling"
        );

        uint256 _collatPrice = oracle.collatPrice();
        uint256 _collatValueE18 = (_collatIn *
            MISSING_PRECISION *
            _collatPrice) / PRICE_PRECISION;
        uint256 _towerOut = (_collatValueE18 * RATIO_PRECISION) / tcr;
        uint256 _requiredCubeAmt = 0;
        uint256 _cubePrice = oracle.cubePrice();

        if (tcr < TCR_MAX) {
            _requiredCubeAmt =
                ((_towerOut - _collatValueE18) * PRICE_PRECISION) /
                _cubePrice;
        }

        uint256 _towerFee = (_towerOut * mintFee) / RATIO_PRECISION;
        _towerOut = _towerOut - _towerFee;
        require(_towerOut >= _towerOutMin, "Bank: slippage");

        if (_requiredCubeAmt > 0) {
            require(_cubeIn >= _requiredCubeAmt, "Bank: not enough CUBE");

            // swap all Cubes to Cube/Usdc LP
            uint256 _minCollatAmt = (_requiredCubeAmt *
                _cubePrice *
                PRICE_PRECISION *
                (RATIO_PRECISION - zapSlippage)) /
                RATIO_PRECISION /
                PRICE_PRECISION /
                _collatPrice /
                2 /
                MISSING_PRECISION;

            cube.safeTransferFrom(msg.sender, address(this), _requiredCubeAmt);
            cube.safeApprove(address(swapController), 0);
            cube.safeApprove(address(swapController), _requiredCubeAmt);
            uint256 _lpAmount = swapController.zapInCube(
                _requiredCubeAmt,
                _minCollatAmt,
                0
            );

            // transfer all lp token to Dustbin
            IERC20 lpToken = IERC20(address(cubePair));
            lpToken.safeTransfer(dustbin, _lpAmount);
        }

        collat.safeTransferFrom(msg.sender, address(safe), _collatIn);
        tower.mintByBank(msg.sender, _towerOut);
        tower.mintByBank(address(profitController), _towerFee);

        emit LogMint(_collatIn, _cubeIn, _towerOut, _towerFee);
    }

    function zapMint(uint256 _collatIn, uint256 _towerOutMin)
        public
        onlyNonContract
        nonReentrant
    {
        require(!zapMintPaused, "Bank: zap mint paused");
        require(_collatIn > 0, "Bank: _collatIn <= 0");

        // Don't take in more collateral than the pool ceiling for this token allows
        require(
            (safe.globalCollateralBalance() + _collatIn) <= poolCeiling,
            "Bank: Pool Ceiling"
        );

        uint256 _collatPrice = oracle.collatPrice();

        uint256 _collatFee = ((_collatIn * mintFee) / RATIO_PRECISION);
        uint256 _towerFee = (_collatFee * MISSING_PRECISION * _collatPrice) /
            PRICE_PRECISION;
        uint256 _collatToMint = _collatIn - _collatFee;
        uint256 _collatToMintE18 = _collatToMint * MISSING_PRECISION;

        uint256 _cubePrice = oracle.cubePrice();
        uint256 _collatToBuy = 0;
        if (tcr < TCR_MAX) {
            _collatToBuy = _collatAmtToBuyShare(
                _collatToMint,
                _collatPrice,
                _cubePrice
            );
            _collatToMintE18 -= (_collatToBuy * MISSING_PRECISION);
        }

        collat.safeTransferFrom(msg.sender, address(this), _collatIn);
        uint256 _lpAmount = 0;
        if (_collatToBuy > 0) {
            collat.safeApprove(address(swapController), 0);
            collat.safeApprove(address(swapController), _collatToBuy);

            uint256 _minCubeAmt = (_collatToBuy *
                PRICE_PRECISION *
                (RATIO_PRECISION - zapSlippage)) /
                _cubePrice /
                RATIO_PRECISION /
                2;

            _lpAmount = swapController.zapInUsdc(_collatToBuy, _minCubeAmt, 0);
            _collatToMintE18 = (_collatToMintE18 * RATIO_PRECISION) / tcr;
            emit ZapSwapped(_collatToBuy, _lpAmount);
        }

        uint256 _towerOut = (_collatToMintE18 * _collatPrice) / PRICE_PRECISION;
        require(_towerOut >= _towerOutMin, "Bank: tower slippage");

        if (_lpAmount > 0) {
            // transfer all lp token to Dustbin
            IERC20 lpToken = IERC20(address(cubePair));
            lpToken.safeTransfer(dustbin, lpToken.balanceOf(address(this)));
        }
        collat.safeTransfer(address(safe), collat.balanceOf(address(this)));
        tower.mintByBank(msg.sender, _towerOut);
        tower.mintByBank(address(profitController), _towerFee);

        emit LogMint(_collatIn, 0, _towerOut, _towerFee);
    }

    function redeem(
        uint256 _towerIn,
        uint256 _cubeOutMin,
        uint256 _collatOutMin
    ) external onlyNonContract nonReentrant {
        require(!redeemPaused, "Bank: redeem paused");
        require(_towerIn > 0, "Bank: tower <= 0");

        uint256 _towerFee = (_towerIn * redeemFee) / RATIO_PRECISION;
        uint256 _towerToRedeem = _towerIn - _towerFee;
        uint256 _cubeOut = 0;
        uint256 _collatOut = (_towerToRedeem * PRICE_PRECISION) /
            oracle.collatPrice() /
            MISSING_PRECISION;

        if (ecr < ECR_MAX) {
            uint256 _cubeOutValue = _towerToRedeem -
                ((_towerToRedeem * ecr) / RATIO_PRECISION);
            _cubeOut = (_cubeOutValue * PRICE_PRECISION) / oracle.cubePrice();
            _collatOut = (_collatOut * ecr) / RATIO_PRECISION;
        }

        require(
            _collatOut <= totalCollatAmt(),
            "Bank: insufficient bank balance"
        );
        require(_collatOut >= _collatOutMin, "Bank: collat slippage");
        require(_cubeOut >= _cubeOutMin, "Bank: cube slippage");

        if (_collatOut > 0) {
            redeemCollatBal[msg.sender] += _collatOut;
            unclaimedCollat += _collatOut;
        }

        if (_cubeOut > 0) {
            redeemCubeBal[msg.sender] += _cubeOut;
            unclaimedCube += _cubeOut;
            cube.mintByBank(address(safe), _cubeOut);
        }

        lastRedeemed[msg.sender] = block.number;

        tower.burn(msg.sender, _towerToRedeem);
        tower.safeTransferFrom(
            msg.sender,
            address(profitController),
            _towerFee
        );

        emit LogRedeem(_towerIn, _collatOut, _cubeOut, _towerFee);
    }

    function collect() external onlyNonContract nonReentrant {
        require(
            lastRedeemed[msg.sender] + 1 <= block.number,
            "Bank: collect too soon"
        );

        uint256 _collatOut = redeemCollatBal[msg.sender];
        uint256 _cubeOut = redeemCubeBal[msg.sender];

        if (_collatOut > 0) {
            redeemCollatBal[msg.sender] = 0;
            unclaimedCollat -= _collatOut;
            safe.transferCollatTo(msg.sender, _collatOut);
        }

        if (_cubeOut > 0) {
            redeemCubeBal[msg.sender] = 0;
            unclaimedCube -= _cubeOut;
            safe.transferCubeTo(msg.sender, _cubeOut);
        }
    }

    function arbMint(uint256 _collatIn) external override nonReentrant onlyArb {
        require(!zapMintPaused, "Bank: zap mint paused");
        require(_collatIn > 0, "Bank: _collatIn <= 0");

        // Don't take in more collateral than the pool ceiling for this token allows
        require(
            (safe.globalCollateralBalance() + _collatIn) <= poolCeiling,
            "Bank: Pool Ceiling"
        );

        uint256 _collatPrice = oracle.collatPrice();
        uint256 _collatToMintE18 = _collatIn * MISSING_PRECISION;

        uint256 _cubePrice = oracle.cubePrice();
        uint256 _collatToBuy = 0;
        if (tcr < TCR_MAX) {
            _collatToBuy = _collatAmtToBuyShare(
                _collatIn,
                _collatPrice,
                _cubePrice
            );
            _collatToMintE18 -= (_collatToBuy * MISSING_PRECISION);
        }

        collat.safeTransferFrom(msg.sender, address(this), _collatIn);
        uint256 _lpAmount = 0;
        if (_collatToBuy > 0) {
            collat.safeApprove(address(swapController), 0);
            collat.safeApprove(address(swapController), _collatToBuy);

            uint256 _minCubeAmt = (_collatToBuy *
                PRICE_PRECISION *
                (RATIO_PRECISION - zapSlippage)) /
                _cubePrice /
                RATIO_PRECISION /
                2;

            _lpAmount = swapController.zapInUsdc(_collatToBuy, _minCubeAmt, 0);

            _collatToMintE18 = (_collatToMintE18 * RATIO_PRECISION) / tcr;
            emit ZapSwapped(_collatToBuy, _lpAmount);
        }

        uint256 _towerOut = (_collatToMintE18 * _collatPrice) / PRICE_PRECISION;

        if (_lpAmount > 0) {
            // transfer all lp token to Dustbin
            IERC20 lpToken = IERC20(address(cubePair));
            lpToken.safeTransfer(dustbin, lpToken.balanceOf(address(this)));
        }
        collat.safeTransfer(address(safe), collat.balanceOf(address(this)));
        tower.mintByBank(msg.sender, _towerOut);
    }

    function arbRedeem(uint256 _towerIn)
        external
        override
        nonReentrant
        onlyArb
    {
        require(!redeemPaused, "Bank: redeem paused");
        require(_towerIn > 0, "Bank: tower <= 0");

        uint256 _cubeOut = 0;
        uint256 _collatOut = (_towerIn * PRICE_PRECISION) /
            oracle.collatPrice() /
            MISSING_PRECISION;

        if (ecr < ECR_MAX) {
            uint256 _cubeOutValue = _towerIn -
                ((_towerIn * ecr) / RATIO_PRECISION);
            _cubeOut = (_cubeOutValue * PRICE_PRECISION) / oracle.cubePrice();
            _collatOut = (_collatOut * ecr) / RATIO_PRECISION;
        }

        require(
            _collatOut <= totalCollatAmt(),
            "Bank: insufficient bank balance"
        );

        if (_collatOut > 0) {
            safe.transferCollatTo(msg.sender, _collatOut);
        }

        if (_cubeOut > 0) {
            cube.mintByBank(msg.sender, _cubeOut);
        }

        tower.burn(msg.sender, _towerIn);
    }

    // When the protocol is recollateralizing, we need to give a discount of CUBE to hit the new CR target
    // Thus, if the target collateral ratio is higher than the actual value of collateral, minters get CUBE for adding collateral
    // This function simply rewards anyone that sends collateral to a pool with the same amount of CUBE + the bonus rate
    // Anyone can call this function to recollateralize the protocol and take the extra CUBE value from the bonus rate as an arb opportunity
    function recollateralize(uint256 _collatIn, uint256 _cubeOutMin)
        external
        nonReentrant
        returns (uint256)
    {
        require(recollatPaused == false, "Bank: Recollat paused");

        // Don't take in more collateral than the pool ceiling for this token allows
        require(
            (safe.globalCollateralBalance() + _collatIn) <= poolCeiling,
            "Bank: Pool Ceiling"
        );

        uint256 _collatInE18 = _collatIn * MISSING_PRECISION;
        uint256 _cubePrice = oracle.cubePrice();
        uint256 _collatPrice = oracle.collatPrice();

        // Get the amount of CUBE actually available (accounts for throttling)
        uint256 _cubeAvailable = recollatAvailable();

        // Calculated the attempted amount of IVORY
        uint256 _cubeOut = (_collatInE18 *
            _collatPrice *
            (RATIO_PRECISION + bonusRate)) /
            RATIO_PRECISION /
            _cubePrice;

        // Make sure there is CUBE available
        require(_cubeOut <= _cubeAvailable, "Bank: Insuf CUBE Avail For RCT");

        // Check slippage
        require(_cubeOut >= _cubeOutMin, "Bank: CUBE slippage");

        // Take in the collateral and pay out the CUBE
        collat.safeTransferFrom(msg.sender, address(safe), _collatIn);
        cube.mintByBank(msg.sender, _cubeOut);

        // Increment the outbound CUBE, in E18
        // Used for recollat throttling
        rctHourlyCum[_curEpochHr()] += _cubeOut;

        emit Recollateralized(_collatIn, _cubeOut);
        return _cubeOut;
    }

    function recollatTheoAvailableE18() public view returns (uint256) {
        uint256 _towerTotalSupply = tower.totalSupply();
        uint256 _desiredCollatE24 = tcr * _towerTotalSupply;
        uint256 _effectiveCollatE24 = calcEcr() * _towerTotalSupply;

        // Return 0 if already overcollateralized
        // Otherwise, return the deficiency
        if (_effectiveCollatE24 >= _desiredCollatE24) return 0;
        else {
            return (_desiredCollatE24 - _effectiveCollatE24) / RATIO_PRECISION;
        }
    }

    function recollatAvailable() public view returns (uint256) {
        uint256 _cubePrice = oracle.cubePrice();

        // Get the amount of collateral theoretically available
        uint256 _recollatTheoAvailableE18 = recollatTheoAvailableE18();

        // Get the amount of CUBE theoretically outputtable
        uint256 _cubeTheoOut = (_recollatTheoAvailableE18 * PRICE_PRECISION) /
            _cubePrice;

        // See how much CUBE has been issued this hour
        uint256 _currentHourlyRct = rctHourlyCum[_curEpochHr()];

        // Account for the throttling
        return _comboCalcBbkRct(_currentHourlyRct, rctMaxPerHour, _cubeTheoOut);
    }

    // Internal functions

    // Returns the current epoch hour
    function _curEpochHr() internal view returns (uint256) {
        return (block.timestamp / 3600); // Truncation desired
    }

    function _comboCalcBbkRct(
        uint256 _cur,
        uint256 _max,
        uint256 _theo
    ) internal pure returns (uint256) {
        if (_max == 0) {
            // If the hourly limit is 0, it means there is no limit
            return _theo;
        } else if (_cur >= _max) {
            // If the hourly limit has already been reached, return 0;
            return 0;
        } else {
            // Get the available amount
            uint256 _available = _max - _cur;

            if (_theo >= _available) {
                // If the the theoretical is more than the available, return the available
                return _available;
            } else {
                // Otherwise, return the theoretical amount
                return _theo;
            }
        }
    }

    function _collatAmtToBuyShare(
        uint256 _collatAmt,
        uint256 _collatPrice,
        uint256 _cubePrice
    ) internal view returns (uint256) {
        uint256 _r0 = 0;
        uint256 _r1 = 0;

        if (address(cube) <= address(collat)) {
            (_r1, _r0, ) = cubePair.getReserves(); // r1 = USDC, r0 = CUBE
        } else {
            (_r0, _r1, ) = cubePair.getReserves(); // r0 = USDC, r1 = CUBE
        }

        uint256 _rSwapFee = RATIO_PRECISION - swapFee;

        uint256 _k = ((RATIO_PRECISION * RATIO_PRECISION) / tcr) -
            RATIO_PRECISION;
        uint256 _b = _r0 +
            ((_rSwapFee *
                _r1 *
                _cubePrice *
                RATIO_PRECISION *
                PRICE_PRECISION) /
                CUBE_PRECISION /
                PRICE_PRECISION /
                _k /
                _collatPrice) -
            ((_collatAmt * _rSwapFee) / PRICE_PRECISION);

        uint256 _tmp = ((_b * _b) / PRICE_PRECISION) +
            ((4 * _rSwapFee * _collatAmt * _r0) /
                PRICE_PRECISION /
                PRICE_PRECISION);

        return
            ((Babylonian.sqrt(_tmp * PRICE_PRECISION) - _b) * RATIO_PRECISION) /
            (2 * _rSwapFee);
    }

    function mintTowerByProfit(uint256 _amount) external onlyOwnerOrOperator {
        require(_amount > 0, "Safe: Zero amount");
        require(ecr > tcr, "Safe: tcr >= ecr");

        uint256 _available = ((tower.totalSupply() * (ecr - tcr))) / tcr;

        _available =
            _available -
            ((_available * safe.excessCollateralSafetyMargin()) /
                RATIO_PRECISION);

        uint256 _ammtToMint = Math.min(_available, _amount);

        tower.mintByBank(address(profitController), _ammtToMint);
    }

    function info()
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        return (tcr, ecr, mintFee, redeemFee);
    }
}
