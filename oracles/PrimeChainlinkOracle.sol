// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {OwnableUpgradeable} from "../../dependencies/openzeppelin/upgradeability/OwnableUpgradeable.sol";
import {IChainlinkAdapter} from "../../interfaces/IChainlinkAdapter.sol";
import {IBaseOracle} from "../../interfaces/IBaseOracle.sol";

/// @title PrimeChainlinkOracle Contract
/// @author Prime
contract PrimeChainlinkOracle is IBaseOracle, OwnableUpgradeable {
	/// @notice Eth price feed
	IChainlinkAdapter public ethChainlinkAdapter;
	/// @notice Token price feed
	IChainlinkAdapter public prfiChainlinkAdapter;

	error AddressZero();

	/**
	 * @notice Initializer
	 * @param _ethChainlinkAdapter Chainlink adapter for ETH.
	 * @param _prfiChainlinkAdapter Chainlink price feed for PRFI.
	 */
	function initialize(address _ethChainlinkAdapter, address _prfiChainlinkAdapter) external initializer {
		require(_ethChainlinkAdapter != address(0), AddressZero());
		require(_prfiChainlinkAdapter != address(0), AddressZero());
		ethChainlinkAdapter = IChainlinkAdapter(_ethChainlinkAdapter);
		prfiChainlinkAdapter = IChainlinkAdapter(_prfiChainlinkAdapter);
		__Ownable_init();
	}

	/**
	 * @notice Returns USD price in quote token.
	 * @dev supports 18 decimal token
	 * @return price of token in decimal 8
	 */
	function latestAnswer() public view returns (uint256 price) {
		// Chainlink param validations happens inside here
		price = prfiChainlinkAdapter.latestAnswer();
	}

	/**
	 * @notice Returns price in ETH
	 * @dev supports 18 decimal token
	 * @return price of token in decimal 8.
	 */
	function latestAnswerInEth() public view returns (uint256 price) {
		uint256 prfiPrice = prfiChainlinkAdapter.latestAnswer();
		uint256 ethPrice = ethChainlinkAdapter.latestAnswer();
		price = (prfiPrice * (10 ** 8)) / ethPrice;
	}

	/**
	 * @dev Check if update() can be called instead of wasting gas calling it.
	 */
	function canUpdate() public pure returns (bool) {
		return false;
	}

	/**
	 * @dev this function only exists so that the contract is compatible with the IBaseOracle Interface
	 */
	function update() public {}

	/**
	 * @notice Returns current price.
	 */
	function consult() public view returns (uint256 price) {
		price = latestAnswer();
	}
}
