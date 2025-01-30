// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {RecoverERC20} from "../libraries/RecoverERC20.sol";
import {IMiddleFeeDistribution} from "../../interfaces/IMiddleFeeDistribution.sol";
import {IMultiFeeDistribution} from "../../interfaces/IMultiFeeDistribution.sol";
import {IMintableToken} from "../../interfaces/IMintableToken.sol";
import {IAaveOracle} from "../../interfaces/IAaveOracle.sol";
import {IAToken} from "../../interfaces/IAToken.sol";
import {IChainlinkAggregator} from "../../interfaces/IChainlinkAggregator.sol";
import {IAaveProtocolDataProvider} from "../../interfaces/IAaveProtocolDataProvider.sol";
import {IPriceProvider} from "../../interfaces/IPriceProvider.sol";

/// @title Fee distributor inside
/// @author Prime
/// @notice Distributes fees to the platform and rewards to stakers
/// @dev This contract is used to distribute fees to the platform and rewards to stakers
contract MiddleFeeDistribution is IMiddleFeeDistribution, Initializable, OwnableUpgradeable, RecoverERC20 {
	using SafeERC20 for IERC20;

	/// @notice prfi token
	IMintableToken public prfiToken;

	/// @notice Fee distributor contract for earnings and prfi lockings
	IMultiFeeDistribution public multiFeeDistribution;

	/// @notice Reward ratio for operation expenses
	uint256 public operationExpenseRatio;

	/// @notice Ratio divisor
	uint256 public constant RATIO_DIVISOR = 10000;

	/// @notice Decimals
	uint8 public constant DECIMALS = 18;

	/// @notice Mapping of reward tokens
	mapping(address => bool) public isRewardToken;

	/// @notice Operation Expense account
	address public operationExpenses;

	/// @notice Admin address
	address public admin;

	// AAVE Oracle address
	address internal _aaveOracle;

	// AAVE Protocol Data Provider address
	IAaveProtocolDataProvider public aaveProtocolDataProvider;

	/********************** Events ***********************/

	/// @notice Emitted when reward token is forwarded
	event ForwardReward(address indexed token, uint256 amount);

	/// @notice Emitted when operation expenses is set
	event OperationExpensesUpdated(address indexed _operationExpenses, uint256 _operationExpenseRatio);

	/// @notice Emitted when new transfer is added
	event NewTransferAdded(address indexed asset, uint256 lpUsdValue);

	/// @notice Emitted when admin is updated
	event AdminUpdated(address indexed _configurator);

	/// @notice Emitted when rewards are updated
	event RewardsUpdated(address indexed _rewardsToken);

	/// @notice Emitted when protocol data provider is updated
	event ProtocolDataProviderUpdated(address indexed _providerAddress);

	/********************** Errors ***********************/

	error ZeroAddress();

	error IncompatibleToken();

	error InvalidRatio();

	error NotMFD();

	error InsufficientPermission();

	/**
	 * @dev Throws if called by any account other than the admin or owner.
	 */
	modifier onlyAdminOrOwner() {
		if (admin != _msgSender() && owner() != _msgSender()) revert InsufficientPermission();
		_;
	}

	constructor() {
		_disableInitializers();
	}

	/**
	 * @notice Initializer
	 * @param prfiToken_ prfi address
	 * @param aaveOracle_ Aave oracle address
	 * @param multiFeeDistribution_ Multi fee distribution contract
	 */
	function initialize(
		IMintableToken prfiToken_,
		address aaveOracle_,
		IMultiFeeDistribution multiFeeDistribution_,
		IAaveProtocolDataProvider aaveProtocolDataProvider_
	) public initializer {
		require(
        	aaveOracle_ != address(0) &&
        	address(prfiToken_) != address(0) &&
        	address(multiFeeDistribution_) != address(0) &&
			address(aaveProtocolDataProvider_) != address(0),
    		ZeroAddress()
		);

		__Ownable_init(_msgSender());

		prfiToken = prfiToken_;
		_aaveOracle = aaveOracle_;
		multiFeeDistribution = multiFeeDistribution_;
		aaveProtocolDataProvider = aaveProtocolDataProvider_;

		admin = _msgSender();
	}

	/**
	 * @notice Set operation expenses account
	 * @param _operationExpenses Address to receive operation expenses
	 * @param _operationExpenseRatio Proportion of operation expense
	 */
	function setOperationExpenses(address _operationExpenses, uint256 _operationExpenseRatio) external onlyOwner {
		require(_operationExpenseRatio <= RATIO_DIVISOR, InvalidRatio());
		require(_operationExpenses != address(0), ZeroAddress());
		operationExpenses = _operationExpenses;
		operationExpenseRatio = _operationExpenseRatio;
		emit OperationExpensesUpdated(_operationExpenses, _operationExpenseRatio);
	}

	/**
	 * @notice Sets pool configurator as admin.
	 * @param _configurator Configurator address
	 */
	function setAdmin(address _configurator) external onlyOwner {
		require(_configurator != address(0), ZeroAddress());
		admin = _configurator;
		emit AdminUpdated(_configurator);
	}

	/**
	 * @notice Set the Protocol Data Provider address
	 * @param _providerAddress The address of the protocol data provider contract
	 */
	function setProtocolDataProvider(IAaveProtocolDataProvider _providerAddress) external onlyOwner {
		require(address(_providerAddress) != address(0), ZeroAddress());
		aaveProtocolDataProvider = _providerAddress;
		emit ProtocolDataProviderUpdated(address(_providerAddress));
	}

	/**
	 * @notice Add a new reward token to be distributed to stakers
	 * @param _rewardsToken address of the reward token
	 */
	function addReward(address _rewardsToken) external onlyAdminOrOwner {
		if (msg.sender != admin) {
			try IAToken(_rewardsToken).UNDERLYING_ASSET_ADDRESS() returns (address underlying) {
				(address aTokenAddress, , ) = aaveProtocolDataProvider.getReserveTokensAddresses(underlying);
				require(aTokenAddress != address(0), IncompatibleToken());
			} catch {
				// _rewardsToken is not an rToken, do nothing
			}
		}
		multiFeeDistribution.addReward(_rewardsToken);
		isRewardToken[_rewardsToken] = true;
		emit RewardsUpdated(_rewardsToken);
	}

	/**
	 * @notice Remove an existing reward token
	 */
	function removeReward(address _rewardsToken) external onlyAdminOrOwner {
		require(_rewardsToken != address(0), ZeroAddress());

		/// @dev Remove reward token from MFD
		multiFeeDistribution.removeReward(_rewardsToken);
		isRewardToken[_rewardsToken] = false;
		emit RewardsUpdated(_rewardsToken);
	}

	/**
	 * @notice Run by MFD to pull pending platform revenue
	 * @param _rewardTokens an array of reward token addresses
	 */
	function forwardReward(address[] memory _rewardTokens) external {
		require(_msgSender() == address(multiFeeDistribution), NotMFD());

		uint256 length = _rewardTokens.length;
		for (uint256 i; i < length; ) {
			address rewardToken = _rewardTokens[i];
			uint256 total = IERC20(rewardToken).balanceOf(address(this));

			if (operationExpenses != address(0) && operationExpenseRatio != 0) {
				uint256 opExAmount = (total * operationExpenseRatio) / RATIO_DIVISOR;
				if (opExAmount != 0) {
					IERC20(rewardToken).safeTransfer(operationExpenses, opExAmount);
				}
			}

			total = IERC20(rewardToken).balanceOf(address(this));
			IERC20(rewardToken).safeTransfer(address(multiFeeDistribution), total);

			if (rewardToken == address(prfiToken)) {
				multiFeeDistribution.vestTokens(address(multiFeeDistribution), total, false);
			}

			emit ForwardReward(rewardToken, total);

			_emitNewTransferAdded(rewardToken, total);
			unchecked {
				i++;
			}
		}
	}

	/**
	 * @notice Returns prfi token address.
	 * @return prfi token address
	 */
	function getPrfiTokenAddress() external view returns (address) {
		return address(prfiToken);
	}

	/**
	 * @notice Returns MFD address.
	 * @return MFD address
	 */
	function getMultiFeeDistributionAddress() external view returns (address) {
		return address(multiFeeDistribution);
	}

	/**
	 * @notice Emit event for new asset reward
	 * @param asset address of transfer assset
	 * @param lpReward amount of rewards
	 */
	function _emitNewTransferAdded(address asset, uint256 lpReward) internal {
		uint256 lpUsdValue;
		if (asset != address(prfiToken)) {
			try IAToken(asset).UNDERLYING_ASSET_ADDRESS() returns (address underlyingAddress) {
				if (underlyingAddress != address(prfiToken)) {
					uint256 assetPrice = IAaveOracle(_aaveOracle).getAssetPrice(underlyingAddress);
					address sourceOfAsset = IAaveOracle(_aaveOracle).getSourceOfAsset(underlyingAddress);
					uint8 priceDecimal = IChainlinkAggregator(sourceOfAsset).decimals();
					uint8 assetDecimals = IERC20Metadata(asset).decimals();
					lpUsdValue =
						(assetPrice * lpReward * (10 ** DECIMALS)) /
						(10 ** priceDecimal) /
						(10 ** assetDecimals);
				} else {
					uint256 assetPrice = IPriceProvider(IMintableToken(prfiToken).priceProvider()).getTokenPriceUsd();
					uint256 priceDecimal = IPriceProvider(IMintableToken(prfiToken).priceProvider()).decimals();
					uint8 assetDecimals = IERC20Metadata(asset).decimals();
					lpUsdValue =
						(assetPrice * lpReward * (10 ** DECIMALS)) /
						(10 ** priceDecimal) /
						(10 ** assetDecimals);
				}
			} catch {
				uint256 assetPrice = IAaveOracle(_aaveOracle).getAssetPrice(asset);
				address sourceOfAsset = IAaveOracle(_aaveOracle).getSourceOfAsset(asset);
				uint8 priceDecimal = IChainlinkAggregator(sourceOfAsset).decimals();
				uint8 assetDecimals = IERC20Metadata(asset).decimals();
				lpUsdValue = (assetPrice * lpReward * (10 ** DECIMALS)) / (10 ** priceDecimal) / (10 ** assetDecimals);
			}
			emit NewTransferAdded(asset, lpUsdValue);
		}
	}

	/**
	 * @notice Added to support recovering any ERC20 tokens inside the contract
	 * @param tokenAddress address of erc20 token to recover
	 * @param tokenAmount amount to recover
	 */
	function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
		_recoverERC20(tokenAddress, tokenAmount);
	}
}
