// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {TransferHelper} from "../libraries/TransferHelper.sol";
import {IStargateRouter, SendParam, MessagingFee, OFTReceipt} from "../../interfaces/IStargateRouter.sol";
import {IRouterETH} from "../../interfaces/IRouterETH.sol";
import {ILendingPool} from "../../interfaces/ILendingPool.sol";
import {IWETH} from "../../interfaces/IWETH.sol";

/*
    Chain Ids for Mainnet
        Ethereum: 30101
        BSC: 30102
        Avalanche: 30106
        Polygon: 30109
        Arbitrum: 30110
        Optimism: 30111
        Fantom: 30112
        Swimmer: 30114
        DFK: 30115
        Harmony: 30116
        Moonbeam: 30126
		Base: 30184

	Chain Ids for Testnet
		Sepolia: 40161
		BNB Testnet: 40102
		Arbitrum Sepolia Testnet: 40231

    Pool Ids
        Ethereum
            USDC: 1
            USDT: 2
            ETH: 13
			METIS: 17
			mETH: 22
        BSC
			USDC: 1
            USDT: 2
        Avalanche
            USDC: 1
            USDT: 2
        Polygon
            USDC: 1
            USDT: 2
        Arbitrum
            USDC: 1
            USDT: 2
            ETH: 13
        Optimism
            USDC: 1
            ETH: 13
        Fantom
            USDC: 1
		Base
			USDC: 1
			ETH: 13
 */

/// @title Borrow gate via stargate
/// @author Prime
contract StargateBorrow is OwnableUpgradeable {
	using SafeERC20 for IERC20;

	/// @notice FEE ratio DIVISOR
	uint256 public constant FEE_PERCENT_DIVISOR = 10000;

	// Max reasonable fee, 1%
	uint256 public constant MAX_REASONABLE_FEE = 100;

	/// @notice Lending Pool address
	ILendingPool public lendingPool;

	// Weth address
	IWETH internal weth;

	// Referral code
	uint16 public constant REFERRAL_CODE = 0;

	/// @notice DAO wallet
	address public daoTreasury;

	/// @notice Cross chain borrow fee ratio
	uint256 public xChainBorrowFeePercent;

	/// @notice asset => poolId; at the moment, pool IDs for USDC and USDT are the same accross all chains
	mapping(address asset => uint32 poolId) public poolIdPerChain;

	/// @notice asset => stargateRouter;
	mapping(address asset => address stargateRouter) public routerPerAsset;

	/// @notice Emitted when DAO address is updated
	event DAOTreasuryUpdated(address indexed _daoTreasury);

	/// @notice Emitted when fee info is updated
	event XChainBorrowFeePercentUpdated(uint256 indexed percent);

	/// @notice Emited when pool ids of assets are updated
	event PoolIDsAndRoutersUpdated(address[] assets, address[] stargateRouters, uint32[] poolIDs);

	/// @notice Error throw when ratio is invalid
	error InvalidRatio();

	/// @notice Error throw when address is zero
	error AddressZero();

	/// @notice Error throw when length mismatch
	error LengthMismatch();

	constructor() {
		_disableInitializers();
	}

	/**
	 * @notice Constructor
	 * @param _lendingPool Lending pool
	 * @param _weth WETH address
	 * @param _treasury Treasury address
	 * @param _xChainBorrowFeePercent Cross chain borrow fee ratio
	 */
	function initialize(
		ILendingPool _lendingPool,
		IWETH _weth,
		address _treasury,
		uint256 _xChainBorrowFeePercent
	) external initializer {
		require(
			address(_lendingPool) != address(0) &&
			address(_weth) != address(0) &&
			_treasury != address(0),
			AddressZero()
		);
		require(_xChainBorrowFeePercent <= MAX_REASONABLE_FEE, InvalidRatio());

		lendingPool = _lendingPool;
		daoTreasury = _treasury;
		xChainBorrowFeePercent = _xChainBorrowFeePercent;
		weth = _weth;
		__Ownable_init(_msgSender());
	}

	receive() external payable {}

	/**
	 * @notice Set DAO Treasury.
	 * @param _daoTreasury DAO Treasury address.
	 */
	function setDAOTreasury(address _daoTreasury) external onlyOwner {
		require(_daoTreasury != address(0), AddressZero());
		daoTreasury = _daoTreasury;
		emit DAOTreasuryUpdated(_daoTreasury);
	}

	/**
	 * @notice Set Cross Chain Borrow Fee Percent.
	 * @param percent Fee ratio.
	 */
	function setXChainBorrowFeePercent(uint256 percent) external onlyOwner {
		require(percent <= MAX_REASONABLE_FEE, InvalidRatio());
		xChainBorrowFeePercent = percent;
		emit XChainBorrowFeePercentUpdated(percent);
	}

	/**
	 * @notice Set pool ids of assets.
	 * @param assets array.
	 * @param poolIDs array.
	 */
	function setPoolIDsAndRouters(
		address[] calldata assets,
		address[] calldata stargateRouters,
		uint32[] calldata poolIDs
	) external onlyOwner {
		require(assets.length == poolIDs.length, LengthMismatch());
		for (uint256 i; i < assets.length; ) {
			address asset = assets[i];
			uint32 poolID = poolIDs[i];
			address stargateRouter = stargateRouters[i];

			poolIdPerChain[asset] = poolID;
			routerPerAsset[asset] = stargateRouter;

			unchecked {
				i++;
			}
		}
		emit PoolIDsAndRoutersUpdated(assets, stargateRouters, poolIDs);
	}

	/**
	 * @notice Get Cross Chain Borrow Fee amount.
	 * @param amount Fee cost.
	 * @return Fee amount for cross chain borrow
	 */
	function getXChainBorrowFeeAmount(uint256 amount) public view returns (uint256) {
		uint256 feeAmount = (amount * (xChainBorrowFeePercent)) / (FEE_PERCENT_DIVISOR);
		return feeAmount;
	}

	/**
	 * @dev Borrow asset for another chain
	 * @param asset for loop
	 * @param amount for the initial deposit
	 * @param interestRateMode stable or variable borrow mode
	 * @param dstChainId Destination chain id
	 **/
	function borrow(address asset, uint256 amount, uint256 interestRateMode, uint32 dstChainId) external payable {
		if (asset == address(weth)) {
			_borrowETH(amount, interestRateMode, dstChainId);
		} else {
			_borrow(asset, amount, interestRateMode, dstChainId);
		}
	}

	/**
	 * @dev Borrow ETH
	 * @param amount for the initial deposit
	 * @param interestRateMode stable or variable borrow mode
	 * @param dstChainId Destination chain id
	 **/
	function _borrowETH(uint256 amount, uint256 interestRateMode, uint32 dstChainId) internal {
		address stargateRouter = routerPerAsset[address(weth)];
		require(stargateRouter != address(0), AddressZero());

		lendingPool.borrow(address(weth), amount, interestRateMode, REFERRAL_CODE, msg.sender);
		weth.withdraw(amount);

		uint256 feeAmount = getXChainBorrowFeeAmount(amount);
		if (feeAmount > 0) {
			TransferHelper.safeTransferETH(daoTreasury, feeAmount);
			amount = amount - feeAmount;
		}

		(uint256 valueToSend, SendParam memory sendParam, MessagingFee memory messagingFee) = prepareTakeTaxi(
			stargateRouter,
			dstChainId,
			amount,
			_msgSender()
		);
		IStargateRouter(stargateRouter).sendToken{value: valueToSend}(sendParam, messagingFee, _msgSender());
	}

	function _borrow(address asset, uint256 amount, uint256 interestRateMode, uint32 dstChainId) internal {
		address stargateRouter = routerPerAsset[asset];
		require(stargateRouter != address(0), AddressZero());

		lendingPool.borrow(asset, amount, interestRateMode, REFERRAL_CODE, _msgSender());

		uint256 feeAmount = getXChainBorrowFeeAmount(amount);
		if (feeAmount > 0) {
			IERC20(asset).safeTransfer(daoTreasury, feeAmount);
			amount = amount - feeAmount;
		}

		IERC20(asset).forceApprove(address(stargateRouter), amount);
		(uint256 valueToSend, SendParam memory sendParam, MessagingFee memory messagingFee) = prepareTakeTaxi(
			stargateRouter,
			dstChainId,
			amount,
			_msgSender()
		);
		IStargateRouter(stargateRouter).sendToken{value: valueToSend}(sendParam, messagingFee, _msgSender());
	}

	function prepareTakeTaxi(
		address _stargate,
		uint32 _dstEid,
		uint256 _amount,
		address _receiver
	) public view returns (uint256 valueToSend, SendParam memory sendParam, MessagingFee memory messagingFee) {
		sendParam = SendParam({
			dstEid: _dstEid,
			to: addressToBytes32(_receiver),
			amountLD: _amount,
			minAmountLD: _amount,
			extraOptions: new bytes(0),
			composeMsg: new bytes(0),
			oftCmd: ""
		});

		IStargateRouter stargate = IStargateRouter(_stargate);

		(, , OFTReceipt memory receipt) = stargate.quoteOFT(sendParam);
		sendParam.minAmountLD = receipt.amountReceivedLD;

		messagingFee = stargate.quoteSend(sendParam, false);
		valueToSend = messagingFee.nativeFee;

		if (stargate.token() == address(0x0)) {
			valueToSend += sendParam.amountLD;
		}
	}

	/**
	 * @notice Allows owner to recover ETH locked in this contract.
	 * @param to ETH receiver
	 * @param value ETH amount
	 */
	function withdrawLockedETH(address to, uint256 value) external onlyOwner {
		TransferHelper.safeTransferETH(to, value);
	}

	function addressToBytes32(address _addr) internal pure returns (bytes32) {
		return bytes32(uint256(uint160(_addr)));
	}
}
