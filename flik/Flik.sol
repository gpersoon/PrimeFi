// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {DustRefunder} from "./helpers/DustRefunder.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IMultiFeeDistribution} from "../../interfaces/IMultiFeeDistribution.sol";
import {ILendingPool, DataTypes} from "../../interfaces/ILendingPool.sol";
import {IPoolHelper} from "../../interfaces/IPoolHelper.sol";
import {IPriceProvider} from "../../interfaces/IPriceProvider.sol";
import {IAaveOracle} from "../../interfaces/IAaveOracle.sol";
import {IChainlinkAggregator} from "../../interfaces/IChainlinkAggregator.sol";
import {IWETH} from "../../interfaces/IWETH.sol";
import {IPriceOracle} from "../../interfaces/IPriceOracle.sol";
import {TransferHelper} from "../libraries/TransferHelper.sol";
import {UniV2Helper} from "../libraries/UniV2Helper.sol";

/// @title Flik contract
/// @author Prime
contract Flik is Initializable, OwnableUpgradeable, PausableUpgradeable, DustRefunder {
	using SafeERC20 for IERC20;

	/// @notice The maximum amount of slippage that a user can set for the execution of Fliks
	/// @dev If the slippage limit of the Flik contract is lower then that of the Compounder, transactions might fail unexpectedly.
	///      Therefore ensure that this slippage limit is equal to that of the Compounder contract.
	uint256 public constant MAX_SLIPPAGE = 8500; //15%

	/// @notice RATIO Divisor
	uint256 public constant RATIO_DIVISOR = 10000;

	/// @notice Base Percent
	uint256 public constant BASE_PERCENT = 100;

	/// @notice Borrow rate mode
	uint256 public constant VARIABLE_INTEREST_RATE_MODE = 2;

	/// @notice We don't utilize any specific referral code for borrows perfomed via fliks
	uint16 public constant REFERRAL_CODE = 0;

	/// @notice Wrapped ETH
	IWETH public weth;

	/// @notice PRFI token address
	address public prfiAddr;

	/// @notice Multi Fee distribution contract
	IMultiFeeDistribution public mfd;

	/// @notice Lending Pool contract
	ILendingPool public lendingPool;

	/// @notice Pool helper contract used for PRFI-WETH swaps
	IPoolHelper public poolHelper;

	/// @notice Price provider contract
	IPriceProvider public priceProvider;

	/// @notice aave oracle contract
	IAaveOracle public aaveOracle;

	/// @notice parameter to set the ratio of ETH in the LP token, can be 2000 for an 80/20 bal lp
	uint256 public ethLPRatio;

	/// @notice AMM router used for all non PRFI-WETH swaps on Arbitrum
	address public uniRouter;

	/********************** Events ***********************/
	/// @notice Emitted when flik is done
	event Flikped(
		bool _borrow,
		uint256 _ethAmt,
		uint256 _prfiAmt,
		address indexed _from,
		address indexed _onBehalf,
		uint256 _lockTypeIndex
	);
	
	/// @notice Emitted when price provider is updated
	event PriceProviderUpdated(address indexed _provider);
	
	/// @notice Emitted when MFD contract is updated
	event MfdUpdated(address indexed _mfdAddr);

	/// @notice Emitted when PoolHelper contract is updated
	event PoolHelperUpdated(address indexed _poolHelper);

	/// @notice Emitted when UniRouter contract is updated
	event UniRouterUpdated(address indexed _uniRouter);

	/********************** Errors ***********************/
	error AddressZero();

	error InvalidRatio();

	error InvalidLockLength();

	error AmountZero();

	error SlippageTooHigh();

	error SpecifiedSlippageExceedLimit();

	error InvalidFlikETHSource();

	error ReceivedETHOnAlternativeAssetFlik();

	error InsufficientETH();

	error EthTransferFailed();

	constructor() {
		_disableInitializers();
	}

	/**
	 * @notice Initializer
	 * @param _rndtPoolHelper Pool helper address used for PRFI-WETH swaps
	 * @param _uniRouter UniV2 router address used for all non PRFI-WETH swaps
	 * @param _lendingPool Lending pool
	 * @param _weth weth address
	 * @param _prfiAddr PRFI token address
	 * @param _ethLPRatio ratio of ETH in the LP token, can be 2000 for an 80/20 bal lp
	 * @param _aaveOracle Aave oracle address
	 */
	function initialize(
		IPoolHelper _rndtPoolHelper,
		address _uniRouter,
		ILendingPool _lendingPool,
		IWETH _weth,
		address _prfiAddr,
		uint256 _ethLPRatio,
		IAaveOracle _aaveOracle
	) external initializer {
		require(
			address(_rndtPoolHelper) != address(0) &&
			address(_uniRouter) != address(0) &&
			address(_lendingPool) != address(0) &&
			address(_weth) != address(0) &&
			_prfiAddr != address(0) &&
			address(_aaveOracle) != address(0), 
			AddressZero()
		);
		require(_ethLPRatio != 0 && _ethLPRatio < RATIO_DIVISOR, InvalidRatio());

		__Ownable_init(_msgSender());
		__Pausable_init();

		lendingPool = _lendingPool;
		poolHelper = _rndtPoolHelper;
		uniRouter = _uniRouter;
		weth = _weth;
		prfiAddr = _prfiAddr;
		ethLPRatio = _ethLPRatio;
		aaveOracle = _aaveOracle;
	}

	receive() external payable {}

	/**
	 * @notice Set Price Provider.
	 * @param _provider Price provider contract address.
	 */
	function setPriceProvider(address _provider) external onlyOwner {
		require(_provider != address(0), AddressZero());
		priceProvider = IPriceProvider(_provider);
		emit PriceProviderUpdated(_provider);
	}

	/**
	 * @notice Set AAVE Oracle used to fetch asset prices in USD.
	 * @param _aaveOracle oracle contract address.
	 */
	function setAaveOracle(address _aaveOracle) external onlyOwner {
		require(_aaveOracle != address(0), AddressZero());
		aaveOracle = IAaveOracle(_aaveOracle);
	}

	/**
	 * @notice Set Multi fee distribution contract.
	 * @param _mfdAddr New contract address.
	 */
	function setMfd(address _mfdAddr) external onlyOwner {
		require(_mfdAddr != address(0), AddressZero());
		mfd = IMultiFeeDistribution(_mfdAddr);
		emit MfdUpdated(_mfdAddr);
	}

	/**
	 * @notice Set Pool Helper contract used fror WETH-PRFI swaps
	 * @param _poolHelper New PoolHelper contract address.
	 */
	function setPoolHelper(address _poolHelper) external onlyOwner {
		require(_poolHelper != address(0), AddressZero());
		poolHelper = IPoolHelper(_poolHelper);
		emit PoolHelperUpdated(_poolHelper);
	}

	/**
	 * @notice Set Univ2 style router contract address used for all non PRFI<>WETH swaps
	 * @param _uniRouter New PoolHelper contract address.
	 */
	function setUniRouter(address _uniRouter) external onlyOwner {
		require(_uniRouter != address(0), AddressZero());
		uniRouter = _uniRouter;
		emit UniRouterUpdated(_uniRouter);
	}

	/**
	 * @notice Returns pool helper address used for PRFI-WETH swaps
	 */
	function getPoolHelper() external view returns (address) {
		return address(poolHelper);
	}

	/**
	 * @notice Returns uni router address used for all non PRFI-WETH swaps
	 */
	function getUniRouter() external view returns (address) {
		return address(uniRouter);
	}

	/**
	 * @notice Get Variable debt token address
	 * @param _asset underlying.
	 */
	function getVDebtToken(address _asset) external view returns (address) {
		DataTypes.ReserveData memory reserveData = lendingPool.getReserveData(_asset);
		return reserveData.variableDebtTokenAddress;
	}

	/**
	 * @notice Calculate amount of specified tokens received for selling PRFI
	 * @dev this function is mainly used to calculate how much of the specified token is needed to match the provided PRFI amount when providing liquidity to an AMM
	 * @param _token address of the token that would be received
	 * @param _amount of PRFI to be sold
	 * @return amount of _token received
	 */
	function quoteFromToken(address _token, uint256 _amount) public view returns (uint256) {
		address weth_ = address(weth);

		/// @dev If the token is not WETH, we need to swap for WETH first
		if (_token != weth_) {
			uint256 wethAmount = poolHelper.quoteFromToken(_amount);
			return UniV2Helper._quoteSwap(uniRouter, weth_, _token, wethAmount);
		}
		return poolHelper.quoteFromToken(_amount);
	}

	/**
	 * @notice Flik tokens to stake LP
	 * @param _borrow option to borrow ETH
	 * @param _asset to be used for flikping
	 * @param _assetAmt amount of weth.
	 * @param _prfiAmt amount of PRFI.
	 * @param _lockTypeIndex lock length index.
	 * @param _slippage maximum amount of slippage allowed for any occurring trades
	 * @return LP amount
	 */
	function flik(
		bool _borrow,
		address _asset,
		uint256 _assetAmt,
		uint256 _prfiAmt,
		uint256 _lockTypeIndex,
		uint256 _slippage
	) public payable whenNotPaused returns (uint256) {
		return
			_flik(_borrow, _asset, _assetAmt, _prfiAmt, msg.sender, msg.sender, _lockTypeIndex, msg.sender, _slippage);
	}

	/**
	 * @notice Flik tokens to stake LP
	 * @dev It will use default lock index
	 * @param _borrow option to borrow ETH
	 * @param _asset to be used for flikping
	 * @param _assetAmt amount of weth.
	 * @param _prfiAmt amount of PRFI.
	 * @param _onBehalf user address to be flikped.
	 * @param _slippage maximum amount of slippage allowed for any occurring trades
	 * @return LP amount
	 */
	function flikOnBehalf(
		bool _borrow,
		address _asset,
		uint256 _assetAmt,
		uint256 _prfiAmt,
		address _onBehalf,
		uint256 _slippage
	) public payable whenNotPaused returns (uint256) {
		uint256 duration = mfd.defaultLockIndex(_onBehalf);
		return _flik(_borrow, _asset, _assetAmt, _prfiAmt, msg.sender, _onBehalf, duration, _onBehalf, _slippage);
	}

	/**
	 * @notice Flik tokens from vesting
	 * @param _borrow option to borrow ETH
	 * @param _asset to be used for flikping
	 * @param _assetAmt amount of _asset tokens used to create dLP position
	 * @param _lockTypeIndex lock length index. cannot be shortest option (index 0)
	 * @param _slippage maximum amount of slippage allowed for any occurring trades
	 * @return LP amount
	 */
	function flikFromVesting(
		bool _borrow,
		address _asset,
		uint256 _assetAmt,
		uint256 _lockTypeIndex,
		uint256 _slippage
	) public payable whenNotPaused returns (uint256) {
		require(_lockTypeIndex != 0, InvalidLockLength());

		/// @dev returns PRFI amount from vesting
		uint256 prfiAmt = mfd.flikVestingToLp(msg.sender);

		return
			_flik(
				_borrow,
				_asset,
				_assetAmt,
				prfiAmt,
				address(this),
				msg.sender,
				_lockTypeIndex,
				msg.sender,
				_slippage
			);
	}

	/**
	 * @notice Calculates slippage ratio from usd value to LP
	 * @param _assetValueUsd amount value in USD used to create LP pair
	 * @param _liquidity LP token amount
	 */
	function _calcSlippage(uint256 _assetValueUsd, uint256 _liquidity) internal returns (uint256 ratio) {
		priceProvider.update();
		uint256 lpAmountValueUsd = (_liquidity * priceProvider.getLpTokenPriceUsd()) / 1e18;
		ratio = (lpAmountValueUsd * (RATIO_DIVISOR)) / (_assetValueUsd);
	}

	/**
	 * @notice Flik into LP
	 * @param _borrow option to borrow ETH
	 * @param _asset that will be used to flik.
	 * @param _assetAmt amount of assets to be flikped
	 * @param _prfiAmt amount of PRFI.
	 * @param _from src address of PRFI
	 * @param _onBehalf of the user.
	 * @param _lockTypeIndex lock length index.
	 * @param _refundAddress dust is refunded to this address.
	 * @param _slippage maximum amount of slippage allowed for any occurring trades
	 * @return liquidity LP amount
	 */
	function _flik(
		bool _borrow,
		address _asset,
		uint256 _assetAmt,
		uint256 _prfiAmt,
		address _from,
		address _onBehalf,
		uint256 _lockTypeIndex,
		address _refundAddress,
		uint256 _slippage
	) internal returns (uint256 liquidity) {
		IWETH weth_ = weth;
		if (_asset == address(0)) {
			_asset = address(weth_);
		}
		if (_slippage == 0) {
			_slippage = MAX_SLIPPAGE;
		} else {
			require(MAX_SLIPPAGE <= _slippage && _slippage <= RATIO_DIVISOR, SpecifiedSlippageExceedLimit());
		}
		bool isAssetWeth = _asset == address(weth_);

		// Handle pure ETH flik
		if (msg.value > 0) {
			require(isAssetWeth, ReceivedETHOnAlternativeAssetFlik());
			require(!_borrow, InvalidFlikETHSource());
			_assetAmt = msg.value;
			weth_.deposit{value: _assetAmt}();
		}
		require(_assetAmt != 0, AmountZero());
		uint256 assetAmountValueUsd = (_assetAmt * aaveOracle.getAssetPrice(_asset)) /
			(10 ** IERC20Metadata(_asset).decimals());

		// Handle borrowing logic
		if (_borrow) {
			// Borrow the asset on the users behalf
			lendingPool.borrow(_asset, _assetAmt, VARIABLE_INTEREST_RATE_MODE, REFERRAL_CODE, msg.sender);

			// If asset isn't WETH, swap for WETH
			if (!isAssetWeth) {
				_assetAmt = UniV2Helper._swap(uniRouter, _asset, address(weth_), _assetAmt);
			}
		} else if (msg.value == 0) {
			// Transfer asset from user
			IERC20(_asset).transferFrom(msg.sender, address(this), _assetAmt);
			if (!isAssetWeth) {
				_assetAmt = UniV2Helper._swap(uniRouter, _asset, address(weth_), _assetAmt);
			}
		}

		weth_.approve(address(poolHelper), _assetAmt);
		//case where prfi is matched with provided ETH
		if (_prfiAmt != 0) {
			// _from == this when flikping from vesting
			if (_from != address(this)) {
				IERC20(prfiAddr).safeTransferFrom(msg.sender, address(this), _prfiAmt);
			}

			IERC20(prfiAddr).forceApprove(address(poolHelper), _prfiAmt);
			liquidity = poolHelper.flikTokens(_assetAmt, _prfiAmt);
			assetAmountValueUsd = (assetAmountValueUsd * RATIO_DIVISOR) / ethLPRatio;
		} else {
			liquidity = poolHelper.flikWETH(_assetAmt);
		}

		/// @dev Check if slippage is within acceptable range
		if (address(priceProvider) != address(0)) {
			require(_calcSlippage(assetAmountValueUsd, liquidity) >= _slippage, SlippageTooHigh());
		}

		/// @dev Stake LP tokens
		IERC20(poolHelper.lpTokenAddr()).forceApprove(address(mfd), liquidity);
		mfd.stake(liquidity, _onBehalf, _lockTypeIndex);
		emit Flikped(_borrow, _assetAmt, _prfiAmt, _from, _onBehalf, _lockTypeIndex);

		_refundDust(prfiAddr, _asset, _refundAddress);
	}

	/**
	 * @notice Pause flikping operation.
	 */
	function pause() external onlyOwner {
		_pause();
	}

	/**
	 * @notice Unpause flikping operation.
	 */
	function unpause() external onlyOwner {
		_unpause();
	}

	/**
	 * @notice Allows owner to recover ETH locked in this contract.
	 * @param to ETH receiver
	 * @param value ETH amount
	 */
	function withdrawLockedETH(address to, uint256 value) external onlyOwner {
		TransferHelper.safeTransferETH(to, value);
	}
}
