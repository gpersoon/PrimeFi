// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OFT} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/OFT.sol";
import {SendParam, MessagingFee, MessagingReceipt, OFTReceipt} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPriceProvider} from "../../interfaces/IPriceProvider.sol";

/// @title Prime token contract with OFT integration
/// @author Prime Devs
contract PrimeToken is OFT, Pausable, ReentrancyGuard {
	/// @notice bridge fee reciever
	address private treasury;

	/// @notice Fee ratio for bridging, in bips
	uint256 public feeRatio;

	/// @notice Divisor for fee ratio, 100%
	uint256 public constant FEE_DIVISOR = 10000;

	/// @notice Max reasonable fee, 1%
	uint256 public constant MAX_REASONABLE_FEE = 100;

	/// @notice PriceProvider, for PRFI price in native fee calc
	IPriceProvider public priceProvider;

	/// @notice Emitted when fee ratio is updated
	event FeeRatioUpdated(uint256 indexed fee);

	/// @notice Emitted when PriceProvider is updated
	event PriceProviderUpdated(IPriceProvider indexed priceProvider);

	/// @notice Emitted when Treasury is updated
	event TreasuryUpdated(address indexed treasury);

	error AmountTooSmall();

	/// @notice Error message emitted when the provided ETH does not cover the bridge fee
	error InsufficientETHForFee();

	/// @notice Emitted when null address is set
	error AddressZero();

	/// @notice Emitted when ratio is invalid
	error InvalidRatio();

	/**
	 * @notice Create PrimeOFT
	 * @param _tokenName token name
	 * @param _symbol token symbol
	 * @param _endpoint LZ endpoint for network
	 * @param _dao DAO address, for initial mint
	 * @param _treasury Treasury address, for fee recieve
	 * @param _mintAmt Mint amount
	 */
	constructor(
		string memory _tokenName,
		string memory _symbol,
		address _endpoint,
		address _dao,
		address _treasury,
		uint256 _mintAmt
	) OFT(_tokenName, _symbol, _endpoint, _msgSender()) Ownable(_msgSender()) {
		if (_endpoint == address(0)) revert AddressZero();
		if (_dao == address(0)) revert AddressZero();
		if (_treasury == address(0)) revert AddressZero();

		treasury = _treasury;

		if (_mintAmt != 0) {
			_mint(_dao, _mintAmt);
		}
	}

	/**
	 * @notice Burn tokens.
	 * @param _amount to burn
	 */
	function burn(uint256 _amount) public {
		_burn(_msgSender(), _amount);
	}

	/**
	 * @notice Pause bridge operation.
	 */
	function pause() public onlyOwner {
		_pause();
	}

	/**
	 * @notice Unpause bridge operation.
	 */
	function unpause() public onlyOwner {
		_unpause();
	}

	function _updatePrice() internal {
		if (address(priceProvider) != address(0)) {
			priceProvider.update();
		}
	}

	/**
	 * @notice Bridge fee amount
	 * @param _prfiAmount amount for bridge
	 * @return bridgeFee calculated bridge fee
	 */
	function getBridgeFee(uint256 _prfiAmount) public view returns (uint256 bridgeFee) {
		if (address(priceProvider) == address(0)) {
			return 0;
		}
		uint256 priceInEth = priceProvider.getTokenPrice();
		uint256 priceDecimals = priceProvider.decimals();
		uint256 prfiInEth = (_prfiAmount * priceInEth * (10 ** 18)) / (10 ** priceDecimals) / (10 ** decimals());
		bridgeFee = (prfiInEth * feeRatio) / FEE_DIVISOR;
	}

	/**
	 * @notice Set fee info
	 * @param _feeRatio ratio
	 */
	function setFeeRatio(uint256 _feeRatio) external onlyOwner {
		if (_feeRatio > MAX_REASONABLE_FEE) revert InvalidRatio();
		feeRatio = _feeRatio;
		emit FeeRatioUpdated(_feeRatio);
	}

	/**
	 * @notice Set price provider
	 * @param _priceProvider address
	 */
	function setPriceProvider(IPriceProvider _priceProvider) external onlyOwner {
		if (address(_priceProvider) == address(0)) revert AddressZero();
		priceProvider = _priceProvider;
		emit PriceProviderUpdated(_priceProvider);
	}

	/**
	 * @notice Set Treasury
	 * @param _treasury address
	 */
	function setTreasury(address _treasury) external onlyOwner {
		if (_treasury == address(0)) revert AddressZero();
		treasury = _treasury;
		emit TreasuryUpdated(_treasury);
	}

	/**
	 * @dev Executes the send operation.
	 * @param _sendParam The parameters for the send operation.
	 * @param _fee The calculated fee for the send() operation.
	 *      - nativeFee: The native fee.
	 *      - lzTokenFee: The lzToken fee.
	 * @param _refundAddress The address to receive any excess funds.
	 * @return msgReceipt The receipt for the send operation.
	 * @return oftReceipt The OFT receipt information.
	 *
	 * @dev MessagingReceipt: LayerZero msg receipt
	 *  - guid: The unique identifier for the sent message.
	 *  - nonce: The nonce of the sent message.
	 *  - fee: The LayerZero fee incurred for the message.
	 */
	function send(
		SendParam calldata _sendParam,
		MessagingFee calldata _fee,
		address _refundAddress
	) external payable override returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt) {
		_updatePrice();
		/// @dev Applies the token transfers regarding this send() operation.
		/// - amountSentLD is the amount in local decimals that was ACTUALLY sent/debited from the sender.
		/// - amountReceivedLD is the amount in local decimals that will be received/credited to the recipient on the remote OFT instance.
		(uint256 amountSentLD, uint256 amountReceivedLD) = _debit(
			msg.sender,
			_sendParam.amountLD,
			_sendParam.minAmountLD,
			_sendParam.dstEid
		);

		uint256 fee = getBridgeFee(amountSentLD);
		if (msg.value < fee) revert InsufficientETHForFee();

		/// @dev Builds the options and OFT message to quote in the endpoint.
		(bytes memory message, bytes memory options) = _buildMsgAndOptions(_sendParam, amountReceivedLD);

		/// @dev Sends the message to the LayerZero endpoint and returns the LayerZero msg receipt.
		msgReceipt = _lzSend(_sendParam.dstEid, message, options, _fee, _refundAddress);
		/// @dev Formulate the OFT receipt.
		oftReceipt = OFTReceipt(amountSentLD, amountReceivedLD);

		if (fee > 0) {
			Address.sendValue(payable(treasury), fee);
		}

		emit OFTSent(msgReceipt.guid, _sendParam.dstEid, msg.sender, amountSentLD, amountReceivedLD);
	}
}
