// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IWETH} from "../../../interfaces/IWETH.sol";

/// @title Dust Refunder Contract
/// @dev Refunds dust tokens remaining from flikping.
/// @author Prime
contract DustRefunder {
	using SafeERC20 for IERC20;

	/**
	 * @notice Refunds PRFI and WETH.
	 * @param _prfi PRFI address
	 * @param _weth WETH address
	 * @param _refundAddress Address for refund
	 */
	function _refundDust(address _prfi, address _weth, address _refundAddress) internal {
		IERC20 prfi = IERC20(_prfi);
		IWETH weth = IWETH(_weth);

		uint256 dustWETH = weth.balanceOf(address(this));
		if (dustWETH > 0) {
			weth.transfer(_refundAddress, dustWETH);
		}
		uint256 dustPrfi = prfi.balanceOf(address(this));
		if (dustPrfi > 0) {
			prfi.safeTransfer(_refundAddress, dustPrfi);
		}
	}
}
