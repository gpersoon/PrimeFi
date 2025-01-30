// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {DustRefunder} from "./DustRefunder.sol";
import {UniswapV2Library} from "../../../uniswap-solc-0.8/libraries/UniswapV2Library.sol";
import {IUniswapV2Pair} from "../../../uniswap-solc-0.8/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {HomoraMath} from "../../../dependencies/math/HomoraMath.sol";
import {IUniswapV2Router02} from "../../../interfaces/uniswap/IUniswapV2Router02.sol";
import {ILiquidityFlik} from "../../../interfaces/ILiquidityFlik.sol";
import {IWETH} from "../../../interfaces/IWETH.sol";

/// @title Uniswap Pool Helper Contract
/// @author Prime
contract UniswapPoolHelper is Initializable, OwnableUpgradeable, DustRefunder {
	using SafeERC20 for IERC20;
	using HomoraMath for uint256;

	/********************** Events ***********************/

	/// @notice Emitted when LiquidityFlik address is updated
	event LiquidityFlikUpdated(address indexed _liquidityFlik);

	/// @notice Emitted when Flik address is updated
	event FlikUpdated(address indexed _flik);

	/********************** Errors ***********************/
	error AddressZero();
	error InsufficientPermission();

	/********************** State Variables ***********************/

	/// @notice LP token address
	address public lpTokenAddr;

	/// @notice PRFI address
	address public prfiAddr;

	/// @notice WETH address
	address public wethAddr;

	/// @notice Uniswap router
	IUniswapV2Router02 public router;

	/// @notice LiquidityFlik contract
	ILiquidityFlik public liquidityFlik;

	/// @notice Flik address
	address public flik;

	constructor() {
		_disableInitializers();
	}

	/**
	 * @notice Initializer
	 * @param _prfiAddr PRFI address
	 * @param _wethAddr WETH address
	 * @param _routerAddr Uniswap router address
	 * @param _liquidityFlik LiquidityFlik addrress
	 */
	function initialize(
		address _prfiAddr,
		address _wethAddr,
		address _routerAddr,
		ILiquidityFlik _liquidityFlik
	) external initializer {
		require(
			_prfiAddr != address(0) &&
			_wethAddr != address(0) &&
			_routerAddr != address(0) &&
			address(_liquidityFlik) != address(0),
			AddressZero()
		);

		__Ownable_init(_msgSender());

		prfiAddr = _prfiAddr;
		wethAddr = _wethAddr;

		router = IUniswapV2Router02(_routerAddr);
		liquidityFlik = _liquidityFlik;
	}

	/**
	 * @notice Initialize PRFI/WETH pool and liquidity to flik 
	 */
	function initializePool() public onlyOwner {
		uint256 uintMax = type(uint256).max;
		address routerAddr = address(router);
		address liquidityFlikAddr = address(liquidityFlik);
		address thisAddr = address(this);

		IERC20 prfi = IERC20(prfiAddr);
		prfi.forceApprove(routerAddr, uintMax);
		prfi.forceApprove(liquidityFlikAddr, uintMax);
		IERC20(wethAddr).approve(liquidityFlikAddr, uintMax);
		IERC20(wethAddr).approve(routerAddr, uintMax);

		router.addLiquidity(
			prfiAddr,
			wethAddr,
			prfi.balanceOf(thisAddr),
			IERC20(wethAddr).balanceOf(thisAddr),
			0,
			0,
			thisAddr,
			block.timestamp * 2
		);

		lpTokenAddr = IUniswapV2Factory(router.factory()).getPair(prfiAddr, wethAddr);

		IERC20 lp = IERC20(lpTokenAddr);
		lp.safeTransfer(_msgSender(), lp.balanceOf(thisAddr));
	}

	/**
	 * @notice Gets needed WETH for adding LP
	 * @param lpAmount LP amount
	 * @return wethAmount WETH amount
	 */
	function quoteWETH(uint256 lpAmount) public view returns (uint256 wethAmount) {
		IUniswapV2Pair lpToken = IUniswapV2Pair(lpTokenAddr);

		(uint256 reserve0, uint256 reserve1, ) = lpToken.getReserves();
		uint256 weth = lpToken.token0() != address(prfiAddr) ? reserve0 : reserve1;
		uint256 prfi = lpToken.token0() == address(prfiAddr) ? reserve0 : reserve1;
		uint256 lpTokenSupply = lpToken.totalSupply();

		uint256 neededPrfi = (prfi * lpAmount) / lpTokenSupply;
		uint256 neededWeth = (prfi * lpAmount) / lpTokenSupply;

		uint256 neededPrfiInWeth = router.getAmountIn(neededPrfi, weth, prfi);
		return neededWeth + neededPrfiInWeth;
	}

	/**
	 * @notice Flik WETH into LP token
	 * @param amount of WETH to add
	 * @return liquidity LP token amount received
	 */
	function flikWETH(uint256 amount) public returns (uint256 liquidity) {
		address sender = _msgSender();
		require(sender == flik, InsufficientPermission());
		IWETH weth = IWETH(wethAddr);
		weth.transferFrom(sender, address(liquidityFlik), amount);
		liquidityFlik.addLiquidityWETHOnly(amount, payable(address(this)));
		IERC20 lp = IERC20(lpTokenAddr);

		liquidity = lp.balanceOf(address(this));
		lp.safeTransfer(sender, liquidity);
		_refundDust(prfiAddr, wethAddr, sender);
	}

	/**
	 * @notice Returns reserve information.
	 * @return prfi PRFI amount
	 * @return weth WETH amount
	 * @return lpTokenSupply LP token supply
	 */
	function getReserves() public view returns (uint256 prfi, uint256 weth, uint256 lpTokenSupply) {
		IUniswapV2Pair lpToken = IUniswapV2Pair(lpTokenAddr);

		(uint256 reserve0, uint256 reserve1, ) = lpToken.getReserves();
		weth = lpToken.token0() != address(prfiAddr) ? reserve0 : reserve1;
		prfi = lpToken.token0() == address(prfiAddr) ? reserve0 : reserve1;

		lpTokenSupply = lpToken.totalSupply();
	}

	// UniV2 / SLP LP Token Price
	// Alpha Homora Fair LP Pricing Method (flash loan resistant)
	// https://cmichel.io/pricing-lp-tokens/
	// https://blog.alphafinance.io/fair-lp-token-pricing/
	// https://github.com/AlphaFinanceLab/alpha-homora-v2-contract/blob/master/contracts/oracle/UniswapV2Oracle.sol
	/**
	 * @notice Returns LP price
	 * @param prfiPriceInEth price of PRFI in ETH
	 * @return priceInEth LP price in ETH
	 */
	function getLpPrice(uint256 prfiPriceInEth) public view returns (uint256 priceInEth) {
		(uint256 prfiReserve, uint256 wethReserve, uint256 lpSupply) = getReserves();

		uint256 sqrtK = HomoraMath.sqrt(prfiReserve * wethReserve).fdiv(lpSupply); // in 2**112

		// prfi in eth, decis 8
		uint256 px0 = prfiPriceInEth * (2 ** 112); // in 2**112
		// eth in eth, decis 8
		uint256 px1 = uint256(100_000_000) * (2 ** 112); // in 2**112

		// fair token0 amt: sqrtK * sqrt(px1/px0)
		// fair token1 amt: sqrtK * sqrt(px0/px1)
		// fair lp price = 2 * sqrt(px0 * px1)
		// split into 2 sqrts multiplication to prevent uint256 overflow (note the 2**112)
		uint256 result = (((sqrtK * 2 * (HomoraMath.sqrt(px0))) / (2 ** 56)) * (HomoraMath.sqrt(px1))) / (2 ** 56);
		priceInEth = result / (2 ** 112);
	}

	/**
	 * @notice Flik WETH and PRFI into LP
	 * @param _wethAmt amount of WETH
	 * @param _prfiAmt amount of PRFI
	 * @return liquidity LP token amount
	 */
	function flikTokens(uint256 _wethAmt, uint256 _prfiAmt) public returns (uint256 liquidity) {
		address sender = _msgSender();
		require(sender == flik, InsufficientPermission());

		address thisAddr = address(this);
		IWETH weth = IWETH(wethAddr);
		
		weth.transferFrom(sender, thisAddr, _wethAmt);
		IERC20(prfiAddr).safeTransferFrom(sender, thisAddr, _prfiAmt);
		liquidityFlik.standardAdd(_prfiAmt, _wethAmt, thisAddr);
		IERC20 lp = IERC20(lpTokenAddr);
		liquidity = lp.balanceOf(thisAddr);
		lp.safeTransfer(sender, liquidity);
		_refundDust(prfiAddr, wethAddr, sender);
	}

	/**
	 * @notice Returns `quote` of PRFI in WETH
	 * @param tokenAmount amount of PRFI
	 * @return optimalWETHAmount WETH amount
	 */
	function quoteFromToken(uint256 tokenAmount) public view returns (uint256 optimalWETHAmount) {
		optimalWETHAmount = liquidityFlik.quoteFromToken(tokenAmount);
	}

	/**
	 * @notice Returns LiquidityFlik address
	 */
	function getLiquidityFlik() public view returns (address) {
		return address(liquidityFlik);
	}

	/**
	 * @notice Sets new LiquidityFlik address
	 * @param _liquidityFlik LiquidityFlik address
	 */
	function setLiquidityFlik(address _liquidityFlik) external onlyOwner {
		require(_liquidityFlik != address(0), AddressZero());
		liquidityFlik = ILiquidityFlik(_liquidityFlik);
		emit LiquidityFlikUpdated(_liquidityFlik);
	}

	/**
	 * @notice Sets new Flik address
	 * @param _flik Flik address
	 */
	function setFlik(address _flik) external onlyOwner {
		require(_flik != address(0), AddressZero());
		flik = _flik;
		emit FlikUpdated(_flik);
	}

	/**
	 * @notice Returns PRFI price in ETH
	 * @return priceInEth price of PRFI
	 */
	function getPrice() public view returns (uint256 priceInEth) {
		(uint256 prfi, uint256 weth, ) = getReserves();
		if (prfi > 0) {
			priceInEth = (weth * (10 ** 8)) / prfi;
		}
	}

	/**
	 * @notice Calculate quote in WETH from token
	 * @param _inToken input token
	 * @param _wethAmount WETH amount
	 * @return tokenAmount token amount
	 */
	function quoteSwap(address _inToken, uint256 _wethAmount) public view returns (uint256 tokenAmount) {
		address[] memory path = new address[](2);
		path[0] = _inToken;
		path[1] = wethAddr;
		uint256[] memory amountsIn = router.getAmountsIn(_wethAmount, path);
		return amountsIn[0];
	}

	/**
	 * @dev Helper function to swap a token to weth given an {_inToken} and swap {_amount}.
	 * Will revert if the output is under the {_minAmountOut}
	 * @param _inToken Input token for swap
	 * @param _amount Amount of input tokens
	 * @param _minAmountOut Minimum output amount
	 */
	function swapToWeth(address _inToken, uint256 _amount, uint256 _minAmountOut) external {
		address sender = _msgSender();
		require(sender == flik, InsufficientPermission());
		address[] memory path = new address[](2);
		path[0] = _inToken;
		path[1] = wethAddr;
		IERC20(_inToken).forceApprove(address(router), _amount);
		router.swapExactTokensForTokens(_amount, _minAmountOut, path, sender, block.timestamp);
	}
}
