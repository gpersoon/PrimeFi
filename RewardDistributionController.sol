//SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import { OptionsBuilder } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import { MessagingParams } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import "../../../interfaces/IChainlinkAggregator.sol";
import "../../../interfaces/IRewardDistributionController.sol";
import "../../../interfaces/IMiddleFeeDistribution.sol";
import "../../../interfaces/IEligibilityDataProvider.sol";
import "../../../interfaces/IMultiFeeDistribution.sol";
import "../../../interfaces/IOnwardIncentivesController.sol";
import "../../../interfaces/ILooper.sol";
import "../../../lending/libraries/math/MathOperations.sol";

contract RewardDistributionController is OApp, IRewardDistributionController, ReentrancyGuard, Pausable {
	using MathOperations for uint256;

	using SafeERC20 for IERC20;

	using OptionsBuilder for bytes;

	using EnumerableSet for EnumerableSet.UintSet;

	/// @notice Event emitted when the bounty manager is updated
	event BountyManagerUpdated(address indexed bountyManager);

	/// @notice Error emitted when the caller is not the pool configurator
	error NotAllowed();

	/// @notice Error emitted when there is nothing to vest
	error NothingToVest();
	
	/// @notice Error emitted when the caller is not the MFD
	error NotMFD();
	
	/// @notice Error emitted when the caller is not the RToken or MFD
	error NotRTokenOrMfd();

	/// @notice Error emitted when the caller is not the bounty manager
	error BountyOnly();

	/// @notice Only the sidechain can call the function
	error OnlySidechain();

	/// @notice Only the main chain can call the function
	error OnlyMainChain();

	/// @notice Only the ChefIncentivesController can call the function
	error OnlyChefIncentivesController();

	/// @notice Zero address
	error ZeroAddress();

	/// @notice Insufficient fee
	error InsufficientFee();

	/// @notice Invalid length
	error InvalidLength();

	/// @notice Invalid chain id
	error InvalidChain();

	/// @notice Emitted when the selected action is invalid
	error InvalidAction();

	/// @notice Unknown pool
	error UnknownPool();

	/// @notice Out of rewards
	error OutOfRewards();

	/// @notice Pool already exists
	error PoolAlreadyExists();

	/// @notice Emitted when the bounty manager is updated
	event Disqualified(address indexed user);

	/// @notice Reward paid
	event RewardPaid(address indexed user, uint256 reward);

	/// @notice Batch alloc points updated
	event BatchAllocPointsUpdated(address[] tokens, uint256[] allocPoints);

	// Info of each pool.
	struct PoolInfo {
		uint256 totalSupply;
		uint256 allocPoint; // How many allocation points assigned to this pool.
		uint256 lastRewardTime; // Last second that reward distribution occurs.
		uint256 accRewardPerShare; // Accumulated rewards per share, times ACC_REWARD_PRECISION. See below.
		IOnwardIncentivesController onwardIncentives;
	}

	// Info of each user.
	// reward = user.`amount` * pool.`accRewardPerShare` - `rewardDebt`
	struct UserInfo {
		uint256 amount;
		uint256 rewardDebt;
		uint256 lastClaimTime;
	}

	/// @notice Info of each pool.
	mapping (address => PoolInfo) public poolInfo;

	/// @notice token => user => Info of each user that stakes LP tokens.
	mapping(address => mapping(address => UserInfo)) public userInfo;

	/// @notice total supply of the protocol by chain eid
	mapping (uint32 => mapping (Token => uint256)) public totalSupplyByChain;

	/// @notice reward token paid 
	mapping (uint32 => mapping(address => uint256)) public userRewardPerTokenPaid;

	/// @notice rewards by chain eid
    mapping (uint32 => mapping(address => uint256)) public rewards;

	/// @notice balances by chain eid
	mapping (uint32 => mapping(address => mapping(Token => uint256))) private _balancesByChain;

	/// @notice total supply of the protocol
	mapping (Token => uint256) public totalSupply;

	/// @notice tokens chainlink aggregators
	mapping (Token => IChainlinkAggregator) public tokenAggregators;

	/// @notice check if token is active
	mapping (Token => bool) public isTokenActive;

	/// @notice returns the token enum by address
	mapping (address => Token) public tokenAddresses;

	/// @notice valid pToken by address
	mapping (address => bool) public validToken;

	/// @notice user prepaid gas for lz operations
	mapping (address => uint256) public userPrepaidGas;

	/// @notice protocol value by chain
	mapping (uint32 => uint256) public protocolValueByChain;

	mapping (Token => int256) public tokenValueInUSD;

	mapping (Token => uint256) public lastOracleUpdateTime;

	uint256 public constant UPDATE_ORACLE_PERIOD = 240 seconds;

	uint256 private constant WHOLE = 1e18; // 100%
	
	uint256 public constant REQUIRED_RATIO_AMOUNT = 5e16; // 5%

	uint128 public constant MAX_GAS_LIMIT = 1_000_000;

	/// @notice Middle Fee Distribution contract
	IMiddleFeeDistribution public rewardMinter;

	/// @notice Pool configurator address
	address public poolConfigurator;

	/// @notice Bounty manager address
	address public bountyManager;

	/// @notice Multi Fee Distributor address
	address public mfd;
	
	/// @notice PRFI token address
	address private _prfiToken;

	/// @notice check if the chain is the main chain
	bool private _isMainChain;

	/// @notice Main chain layer zero ID (EID)
	uint32 private _mainChain;

	/// @notice Sidechains layer zero IDs (EIDs)
	EnumerableSet.UintSet private _sidechains;

	/// @notice timestamp of the finish time
	uint256 public periodFinish;

	/// @notice PRFI per second
    uint256 public prfiPerSecond;

	/// @notice rewards duration in seconds
    uint256 public rewardsDuration;

	/// @notice last time rewards were updated
    uint256 public lastUpdateTime;

	/// @notice reward per token stored
	uint256 public rewardPerTokenStored;

	/// @notice total protocol value
	uint256 public totalProtocolValue;

	/// @notice total alloc point
	uint256 public totalAllocPoint;

	/// @notice rewards start time
	uint256 public startTime;

	/// @notice list of registered tokens
	address[] public registeredTokens;

	/// @notice Only side chain can call the function
	modifier onlySidechain() {
		require(!_isMainChain, OnlySidechain());
		_;
	}

	/// @notice Only main chain can call the function
	modifier onlyMainChain() {
		require(_isMainChain, OnlyMainChain());
		_;
	}
	
	/// @notice update rewards for every action
	modifier updateReward(address account, uint32 chainEid) {
		uint256 beforeVal = protocolValueByChain[chainEid];
		uint256 afterVal = _calculateProtocolValueInUSD(chainEid);  
		protocolValueByChain[chainEid] = afterVal;  
		totalProtocolValue = totalProtocolValue.sub(beforeVal).add(afterVal);
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0) && isEligibleForRewards(account, chainEid)) {
			mapping (address => uint256) storage _rewards = rewards[chainEid];
			mapping (address => uint256) storage _userRewardPerTokenPaid = userRewardPerTokenPaid[chainEid];
            _rewards[account] = earned(account, chainEid);
            _userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

	constructor(
		address endpoint_, 
		address delegate_, 
		address prfiToken_,
		uint32 mainChain_
	) Ownable(_msgSender()) OApp(endpoint_, delegate_) {
		if (mainChain_ == 0) {
			_isMainChain = true;
		}
		_prfiToken = prfiToken_;
		_mainChain = mainChain_;
		
		periodFinish = block.timestamp;

		startTime = block.timestamp;
	}

	/**
     * @notice Returns the end time of the reward period
     * @return The end time of the reward period
     */
	function endRewardTime() public view returns (uint256) {
		return periodFinish;
	}

	/**
     * @notice Returns all pending rewards for a user
     * @param _user The address of the user
     * @return pending The total pending rewards for the user
     */
	function allPendingRewards(address _user) public view returns (uint256 pending) {
		uint256 length = registeredTokens.length;
		address[] memory tokens = new address[](length);
		for (uint256 i; i < length; i++) {
			tokens[i] = registeredTokens[i];
		}

		uint256 chainLength = _sidechains.length();
		
		for(uint32 j; j < chainLength; j++) {
			uint32 chainEid = uint32(_sidechains.at(j));
			uint256[] memory _rewards = pendingRewards(chainEid, _user, tokens);
			for (uint256 k; k < length; k++) {
				pending = pending.add(_rewards[k]);
			}
		}
	}

	/**
     * @notice Checks if the current chain is the main chain
     * @return True if the current chain is the main chain, false otherwise
     */
	function isMainChain() public view returns (bool) {
		return _isMainChain;
	}

	/**
     * @notice Sets the pool configurator address
     * @param _poolConfigurator The address of the pool configurator
     */
	function setPoolConfigurator(address _poolConfigurator) external onlyOwner {
		require(_poolConfigurator != address(0), ZeroAddress());
		poolConfigurator = _poolConfigurator;
	}

	/**
     * @notice Sets the MFD address
     * @param mfd_ The address of the MFD
     */
	function setMfd(address mfd_) external onlyOwner {
		mfd = mfd_;
	}
	
	/**
     * @notice Sets the reward minter address
     * @param rewardMinter_ The address of the reward minter
     */
	function setRewardMinter(address rewardMinter_) external onlyOwner {
		rewardMinter = IMiddleFeeDistribution(rewardMinter_);
	}

	/**
     * @notice Sets the token addresses
     * @param tokenEnums The array of token enums
     * @param tokens The array of token addresses
     */
	function setTokenAddresses(Token[] memory tokenEnums, address[] memory tokens) external onlyOwner {
		require(tokens.length == tokenEnums.length, InvalidLength());
		for (uint256 i; i < tokenEnums.length; i++) {
			Token token = tokenEnums[i];
			tokenAddresses[tokens[i]] = token;
		}
	}

	/** 
	 * @notice notifies the contract about the amount of PRFI to be distributed
	 * @param reward The amount of PRFI to be distributed
	 * @param finishTimestamp The timestamp when the distribution will end
	 */
	function notifyRewardAmount(uint256 reward, uint256 finishTimestamp) external onlyOwner onlyMainChain updateReward(address(0), 0) {
		uint256 blockTimestamp = block.timestamp;
		uint256 _rewardsDuration = finishTimestamp - blockTimestamp;
		rewardsDuration = _rewardsDuration;
        if (blockTimestamp >= periodFinish) {
            prfiPerSecond = reward.div(_rewardsDuration);
        } else {
            uint256 remaining = periodFinish.sub(blockTimestamp);
            uint256 leftover = remaining.mul(prfiPerSecond);
            prfiPerSecond = reward.add(leftover).div(_rewardsDuration);
        }

        lastUpdateTime = blockTimestamp;
        periodFinish = finishTimestamp;
    }

	/**
     * @notice Returns the pending rewards for a user on a specific chain
     * @param chainEid The ID of the chain
     * @param _user The address of the user
     * @param _tokens The array of token addresses
     * @return rewards_ The array of pending rewards for the user
     */
	function pendingRewards(uint32 chainEid, address _user, address[] memory _tokens) public view returns (uint256[] memory) {
		uint256 length = _tokens.length;
		uint256[] memory rewards_ = new uint256[](length);
		if (length == 0) {
			return rewards_;
		}
		uint256[] memory _tokenValuesInUSD = new uint256[](length);
		mapping(Token => uint256) storage _tokenBalances = _balancesByChain[chainEid][_user];
		mapping (address => uint256) storage _userRewardPerTokenPaid = userRewardPerTokenPaid[chainEid];
		uint256 totalBalancesInUSD;
		uint256 prfiValueInUSD;
		for (uint256 i; i < length; i++) {
			address token = _tokens[i];
			Token tokenEnum = tokenAddresses[token];
			if (tokenEnum == Token.INVALID_TOKEN) {
				continue;
			}
			uint256 amount = _tokenBalances[tokenEnum];
			uint256 _tokenBalanceValueInUSD = _getTokenValueInUSD(tokenEnum, amount);
			if (tokenEnum == Token.PRFI) {
				prfiValueInUSD = _tokenBalanceValueInUSD;
				if (prfiValueInUSD == 0) {
					return rewards_;
				}
			}
			totalBalancesInUSD = totalBalancesInUSD.add(_tokenBalanceValueInUSD);
			_tokenValuesInUSD[i] = _tokenBalanceValueInUSD;
		}

		if (totalBalancesInUSD.mul(WHOLE).div(prfiValueInUSD) < REQUIRED_RATIO_AMOUNT) {
			return rewards_;
		}

		for (uint256 i; i < length; i++) {
			if (_tokenValuesInUSD[i] == 0) {
				continue;
			}
			rewards_[i] = _tokenValuesInUSD[i].mul(rewardPerToken().sub(_userRewardPerTokenPaid[_user])).div(1e18);
		}

		return rewards_;
	}

	/**
     * @notice Checks if a user is eligible for rewards on a specific chain
     * @param user The address of the user
     * @param chainEid The ID of the chain
     * @return True if the user is eligible for rewards, false otherwise
     */
	function isEligibleForRewards(address user, uint32 chainEid) public view onlyMainChain returns (bool) {
		uint256 prfiValueInUSD;
		uint256 balancesInUSD;
		mapping(Token => uint256) storage _tokenBalances = _balancesByChain[chainEid][user];
		for (uint256 i = 1; i <= uint(type(Token).max); i++) {
			Token token = Token(i);
			if (!isTokenActive[token]) {
				continue;
			}
			uint256 amount = _tokenBalances[token];
			uint256 _tokenBalanceValueInUSD = _getTokenValueInUSD(token, amount);
			if (token == Token.PRFI) {
				if (_tokenBalanceValueInUSD == 0) {
					return false;
				}
				prfiValueInUSD = _tokenBalanceValueInUSD;
			}
			balancesInUSD = balancesInUSD.add(_tokenBalanceValueInUSD);
		}

		return (balancesInUSD.mul(WHOLE).div(prfiValueInUSD) > REQUIRED_RATIO_AMOUNT);
	}

	/**
     * @notice Returns the last time the reward is applicable
     * @return The last time the reward is applicable
     */
	function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

	/**
     * @notice Returns the reward per token
     * @return The reward per token
	 * @dev The reward per token is calculated by adding the reward per token stored to the
	 * difference between the last time the reward is applicable and the last update time
	 * multiplied by the PRFI per second and the value of WHOLE divided by the total PRFI in the protocol
     */
    function rewardPerToken() public view returns (uint256) {
        if (totalProtocolValue == 0) {
            return 0;
        }
        return
            rewardPerTokenStored.add(
                lastTimeRewardApplicable().sub(lastUpdateTime).mul(prfiPerSecond).mul(WHOLE).div(totalProtocolValue)
            );
    }

	/**
     * @notice Returns the reward earned by a user on a specific chain
     * @param account The address of the user
     * @param chainEid The ID of the chain
     * @return The reward earned by the user
     */
    function earned(address account, uint32 chainEid) public view returns (uint256) {
		mapping(Token => uint256) storage _tokenBalances = _balancesByChain[chainEid][account];
		mapping(Token => uint256) storage _totalSupply = totalSupplyByChain[chainEid];
		mapping (address => uint256) storage _userRewardPerTokenPaid = userRewardPerTokenPaid[chainEid];
		uint256 userPrfiValueInUSD;
		uint256 balancesInUSD;
		uint256 protocolValueInUSD;
		for (uint256 i = 1; i <= uint(type(Token).max); i++) {
			Token token = Token(i);
			if (!isTokenActive[token]) {
				continue;
			}
			uint256 amount = _tokenBalances[token];
			uint256 protocolSupply = _totalSupply[token];
			uint256 _tokenBalanceValueInUSD = _getTokenValueInUSD(token, amount);
			uint256 _protocolValueInUSD = _getTokenValueInUSD(token, protocolSupply);
			if (token == Token.PRFI) {
				if (_tokenBalanceValueInUSD == 0) {
					return rewards[chainEid][account];
				}
				userPrfiValueInUSD = _tokenBalanceValueInUSD;
			}
			balancesInUSD = balancesInUSD.add(_tokenBalanceValueInUSD);
			protocolValueInUSD = protocolValueInUSD.add(_protocolValueInUSD);
		}

		if (balancesInUSD.mul(WHOLE).div(userPrfiValueInUSD) < REQUIRED_RATIO_AMOUNT) {
			return rewards[chainEid][account];
		}

        return balancesInUSD.mul(rewardPerToken().sub(_userRewardPerTokenPaid[account])).div(protocolValueInUSD).add(rewards[chainEid][account]);
    }

	/**
     * @notice Returns the reward for the duration
     * @return The reward for the duration
	 * @dev The reward is calculated by multiplying the PRFI per second by the rewards duration
     */
    function getRewardForDuration() external view returns (uint256) {
        return prfiPerSecond.mul(rewardsDuration);
    }

	/**
	 * @notice Sets the PRFI token
	 * @param prfiToken_ The address of the PRFI token
	 */
	function setPrfiToken(address prfiToken_) external onlyOwner {
		_prfiToken = prfiToken_;
	}

	/**
	 * @notice Sets the Chainlink aggregator for a token
	 * @param tokens_ The tokens to set the Chainlink aggregator for
	 * @param aggregators_ The Chainlink aggregators for the tokens
	 */
	function setTokenAggregators(Token[] memory tokens_, IChainlinkAggregator[] memory aggregators_) external onlyOwner {
		require(tokens_.length == aggregators_.length, InvalidLength());
		for (uint256 i; i < tokens_.length; i++) {
			if (tokens_[i] == Token.INVALID_TOKEN) {
				continue;
			}
			
			_setTokenAggregator(tokens_[i], aggregators_[i]);

			isTokenActive[tokens_[i]] = true;
		}
	}
	
	/** 
	 * @notice removes the Chainlink aggregator for a token
	 * @param token The token to remove the Chainlink aggregator for
	*/
	function removeTokenAggregator(Token token) external onlyOwner {
		require(token != Token.INVALID_TOKEN, InvalidChain());
		isTokenActive[token] = false;
		delete tokenAggregators[token];
	}

	/**
	 * @notice Sets the main chain
	 * @param mainChain_ The main chain layer zero ID
	 */
	function setMainChain(uint32 mainChain_) external onlyOwner {
		_isMainChain = (mainChain_ == 0);
		_mainChain = mainChain_;
	}

	/**
	 * @notice Sets the amount of PRFI that will be distributed per second
	 * @param prfiPerSecond_ The PRFI per second amount
	 */
	function setPrfiPerSecond(uint256 prfiPerSecond_) external onlyOwner onlyMainChain {
		prfiPerSecond = prfiPerSecond_;
	}

	/**
	 * @notice Quotes the fee for sending a message
	 * @param _data The message to send
	 * @return nativeFee The native fee
	 * @return lzTokenFee The LZ token fee
	 */
	function quote(
		bytes memory _data // The message to send.
	) public view returns (uint256 nativeFee, uint256 lzTokenFee) {
		bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(MAX_GAS_LIMIT, 0); 
		MessagingFee memory fee = _quote(_mainChain, _data, options, false);
		return (fee.nativeFee, fee.lzTokenFee);
	}

	/**
	 * @notice Deposits the user's tokens
	 * @param token The token to deposit
	 * @param userData The user data
	 */
	function _updateBalance(uint32 srcEid, Token token, UserData memory userData, uint256 totalSupply_) internal nonReentrant updateReward(userData.user, srcEid) {
		address user = userData.user;
		uint256 amount = userData.amount;
		mapping(Token => uint256) storage chainSupply = totalSupplyByChain[srcEid];
		mapping(Token => uint256) storage userChainBalances = _balancesByChain[srcEid][user];

		uint256 previousUserAmount = userChainBalances[token];

		if (amount > previousUserAmount) {
			uint256 diff = amount.sub(previousUserAmount);
			chainSupply[token] = chainSupply[token].add(diff);
		} else {
			uint256 diff = previousUserAmount.sub(amount);
			chainSupply[token] = chainSupply[token].sub(diff);
		}
		totalSupply[token] = totalSupply_;
		userChainBalances[token] = amount;
    }

	/**
	 * @notice Claims the user's rewards
	 * @param _user The address of the user
	 * @dev The user's rewards are claimed by setting the user's rewards to zero
	 * and vesting the rewards into the MFD
	 */
	function _claim(uint32 _srcEid, address _user) public nonReentrant updateReward(_user, _srcEid) {
		uint256 reward = rewards[_srcEid][_user];
		if (reward > 0) {
			rewards[_srcEid][_user] = 0;
			_vestTokens(_user, reward);
			emit RewardPaid(_user, reward);
		}
	}

	/**
	 * @notice Returns the value of a token in USD
	 * @param token The token to get the value of
	 * @param amount The amount of the token
	 * @return The value of the token in USD
	 * @dev The value of a token is calculated by multiplying the price of the token by the amount of the token
	 */
	function _getAndUpdateTokenValueInUSD(Token token, uint256 amount) internal returns (uint256) {
		IChainlinkAggregator aggregator = tokenAggregators[token];
		require(address(aggregator) != address(0), ZeroAddress());
		int256 price;
		if (block.timestamp > lastOracleUpdateTime[token] + UPDATE_ORACLE_PERIOD) {
			// Update the oracle price
			(,price,,,) = aggregator.latestRoundData();
			tokenValueInUSD[token] = price;
			lastOracleUpdateTime[token] = block.timestamp;
		} else {
			price = tokenValueInUSD[token];
		}
		uint8 decimals = aggregator.decimals();
		return uint256(price).mul(amount).mul(WHOLE).div(10 ** decimals);
	}

	/**
	 * @notice Returns the value of a token in USD
	 * @param token The token to get the value of
	 * @param amount The amount of the token
	 * @return The value of the token in USD
	 * @dev The value of a token is calculated by multiplying the price of the token by the amount of the token
	 */
	function _getTokenValueInUSD(Token token, uint256 amount) internal view returns (uint256) {
		IChainlinkAggregator aggregator = tokenAggregators[token];
		require(address(aggregator) != address(0), ZeroAddress());
		(,int256 price,,,) = aggregator.latestRoundData();
		uint8 decimals = aggregator.decimals();
		return uint256(price).mul(amount).mul(WHOLE).div(10 ** decimals);
	}

	/**
	 * @notice Sets the Chainlink aggregator for a token
	 * @param token The token to set the Chainlink aggregator for
	 * @param aggregator The Chainlink aggregator for the token
	 */
	function _setTokenAggregator(Token token, IChainlinkAggregator aggregator) internal {
		require(address(aggregator) != address(0), ZeroAddress());
		tokenAggregators[token] = aggregator;
	}

	/**
	 * @notice Calculates the value of the protocol in USD
	 * @return The value of the protocol in USD
	 * @dev The value of the protocol is calculated by summing the value of all the tokens in the protocol
	 */
	function _calculateProtocolValueInUSD(uint32 _chainEid) internal returns (uint256) {
		uint256 protocolValueInUSD;
		mapping (Token => uint256) storage _totalSupply = totalSupplyByChain[_chainEid];
		for (uint256 i = 1; i <= uint(type(Token).max); i++) {
			Token token = Token(i);
			if (!isTokenActive[token]) {
				continue;
			}
			uint256 protocolSupply = _totalSupply[token];
			protocolValueInUSD = protocolValueInUSD.add(_getAndUpdateTokenValueInUSD(token, protocolSupply));
		}
		return protocolValueInUSD;
	}

	/**
	 * @notice Sends a message from the source to destination chain.
	 * @param _dstEid Destination chain's endpoint ID.
	 * @param _data The message to send.
	 * @param _options Message execution options (e.g., for sending gas to destination).
	 */
	function _send(uint32 _dstEid, bytes memory _data, bytes memory _options, MessagingFee memory _fee, address payable _refundAddress) internal {
		_lzSend(
			_dstEid, // Destination chain's endpoint ID.
			_data, // Encoded message payload being sent.
			_options, // Message execution options (e.g., gas to use on destination).
			_fee, // Fee struct containing native gas and ZRO token.
			_refundAddress // The refund address in case the send call reverts.
		);
	}

	/**
     * @dev Internal function to interact with the LayerZero EndpointV2.send() for sending a message.
     * @param _dstEid The destination endpoint ID.
     * @param _message The message payload.
     * @param _options Additional options for the message.
     * @param _fee The calculated LayerZero fee for the message.
     *      - nativeFee: The native fee.
     *      - lzTokenFee: The lzToken fee.
     * @param _refundAddress The address to receive any excess fee values sent to the endpoint.
     * @return receipt The receipt for the sent message.
     *      - guid: The unique identifier for the sent message.
     *      - nonce: The nonce of the sent message.
     *      - fee: The LayerZero fee incurred for the message.
     */
    function _lzSend(
        uint32 _dstEid,
        bytes memory _message,
        bytes memory _options,
        MessagingFee memory _fee,
        address _refundAddress
    ) internal override returns (MessagingReceipt memory receipt) {
        // @dev Push corresponding fees to the endpoint, any excess is sent back to the _refundAddress from the endpoint.
		require(address(this).balance >= _fee.nativeFee, InsufficientFee());
        if (_fee.lzTokenFee > 0) _payLzToken(_fee.lzTokenFee);

        return
            // solhint-disable-next-line check-send-result
            endpoint.send{ value: _fee.nativeFee }(
                MessagingParams(_dstEid, _getPeerOrRevert(_dstEid), _message, _options, _fee.lzTokenFee > 0),
                _refundAddress
            );
    }

	/**
	 * @dev Called when data is received from the protocol. It overrides the equivalent function in the parent contract.
	 * Protocol messages are defined as packets, comprised of the following parameters.
	 * @param _origin A struct containing information about where the packet came from.
	 * @param _guid A global unique identifier for tracking the packet.
	 * @param payload Encoded message.
	 */
	function _lzReceive(
		Origin calldata _origin,
		bytes32 _guid,
		bytes calldata payload,
		address, // Executor address as specified by the OApp.
		bytes calldata // Any extra data or options to trigger on receipt.
	) internal override {
		// Decode the message payload.
		(ActionType action, bytes memory actionData, uint256 totalSupply_) = abi.decode(payload, (ActionType, bytes, uint256));

		(Token token, UserData memory userData) = abi.decode(actionData, (Token, UserData));
		// Perform the action based on the decoded message.
		if (action == ActionType.UpdateBalance) {
			_updateBalance(_origin.srcEid, token, userData, totalSupply_);
		} else if (action == ActionType.Claim) {
			_claim(_origin.srcEid, userData.user);
		} else {
			revert InvalidAction();
		}
	}
	/**
	 * @dev Returns address of MFD.
	 * @return mfd contract address
	 */
	function _getMfd() internal view returns (IMultiFeeDistribution) {
		return IMultiFeeDistribution(mfd);
	}

	/**
	 * @dev Updates bounty manager contract.
	 * @param _bountyManager Bounty Manager contract.
	 */
	function setBountyManager(address _bountyManager) external onlyOwner {
		bountyManager = _bountyManager;
		emit BountyManagerUpdated(_bountyManager);
	}

	/********************** Pool Setup + Admin ***********************/

	/**
	 * @dev Add a new lp to the pool. Can only be called by the poolConfigurator.
	 * @param _token for reward pool
	 * @param _allocPoint allocation point of the pool
	 */
	function addPool(address _token, uint256 _allocPoint) external {
		require(msg.sender == poolConfigurator, NotAllowed());
		require(validToken[_token] == false, PoolAlreadyExists());
		validToken[_token] = true;
		totalAllocPoint = totalAllocPoint.add(_allocPoint);
		registeredTokens.push(_token);
		PoolInfo storage pool = poolInfo[_token];
		pool.allocPoint = _allocPoint;
		pool.lastRewardTime = block.timestamp;
		pool.onwardIncentives = IOnwardIncentivesController(address(0));
	}

	function poolLength() external view returns (uint256) {
		return registeredTokens.length;
	}

	/**
	 * @notice Claim rewards. They are vested into MFD.
	 * @param _user address for claim
	 */
	function claim(address _user, address[] memory /*_tokens*/) public {
		claimAll(_user);
	}

	/**
	 * @notice Claim rewards. They are vested into MFD.
	 * @param _user address to receive the rewards
	 */
	function claimAll(address _user) public payable whenNotPaused {
		if (isMainChain()) {
			_claim(0, _user);
		} else {
			// Prepare the LZ OAPP to send a Claim message to the main chain
			// The message will contain the user's address
			// The message will be sent to the main chain
			ActionType action = ActionType.Claim;

			UserData memory userData = UserData({
				user: _user,
				amount: 0
			});

			Token token = Token.PRFI;

			bytes memory actionData = abi.encode(token, userData);

			bytes memory payload = abi.encode(action, actionData);

			bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(MAX_GAS_LIMIT, 0);

			MessagingFee memory fee = _quote(_mainChain, payload, options, false);

			require(msg.value >= fee.nativeFee, InsufficientFee());

			_send(_mainChain, payload, options, fee, payable(address(this)));
		}
	}

	/**
	 * @notice Vest tokens to MFD.
	 * @param _user address to receive
	 * @param _amount to vest
	 */
	function _vestTokens(address _user, uint256 _amount) internal {
		require(_amount != 0, NothingToVest());
		IMultiFeeDistribution _mfd = _getMfd();
		_sendPrime(address(_mfd), _amount);
		_mfd.vestTokens(_user, _amount, true);
	}

	/********************** Eligibility + Disqualification ***********************/
	/**
	 * @notice `after` Hook for deposit and borrow update.
	 * @dev important! eligible status can be updated here
	 * @param _user address
	 * @param _balance balance of token
	 * @param _totalSupply total supply of the token
	 */
	function handleActionAfter(address _user, uint256 _balance, uint256 _totalSupply) external {
		Token token = tokenAddresses[msg.sender];
		require((token != Token(0) && validToken[msg.sender]) || msg.sender == address(_getMfd()), NotRTokenOrMfd());

		if (_user == address(rewardMinter) || _user == address(_getMfd())) {
			return;
		}
		UserData memory userData = UserData({
			user: _user,
			amount: _balance
		});
		
		if (isMainChain()) {
			_updateBalance(0, token, userData, _totalSupply);
		} else {
			// Prepare the LZ OAPP to send a Borrow or Deposit message to the main chain
			// The message will contain the user's address, the token address, and the amount
			// The message will be sent to the main chain
			ActionType action = ActionType.UpdateBalance;

			bytes memory actionData = abi.encode(token, userData);

			bytes memory payload = abi.encode(action, actionData, _totalSupply);

			bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(MAX_GAS_LIMIT, 0);

			MessagingFee memory fee = _quote(_mainChain, payload, options, false);

			require(userPrepaidGas[_user] >= fee.nativeFee, InsufficientFee());

			userPrepaidGas[_user] = userPrepaidGas[_user].sub(fee.nativeFee);

			_send(_mainChain, payload, options, fee, payable(address(this)));
		}
	}

	/**
	 * @notice `before` Hook for deposit and borrow update.
	 * @param _user address
	 */
	function handleActionBefore(address _user) external {}

	/**
	 * @notice Hook for lock update.
	 * @dev Called by the locking contracts before locking or unlocking happens
	 * @param _user address
	 */
	function beforeLockUpdate(address _user) external {}

	/**
	 * @notice Hook for lock update.
	 * @dev Called by the locking contracts after locking or unlocking happens
	 * @param _user address
	 */
	function afterLockUpdate(address _user) external {}

	/**
	 * @notice Prepay gas for actions execution on sidechains
	 */
	function prepayActionsExecution() external onlySidechain payable {
		address _user = _msgSender();
		uint256 _amount = msg.value;
		userPrepaidGas[_user] = userPrepaidGas[_user].add(_amount);
	}

	/**
	 * @notice Withdraw prepaid gas
	 * @dev User can withdraw prepaid gas if they have any
	 */
	function withdrawPrepaidGas() external {
		address _user = _msgSender();
		uint256 _amount = userPrepaidGas[_user];
		require(_amount > 0, InsufficientFee());
		delete userPrepaidGas[_user];
		payable(_user).transfer(_amount);
	}

	/**
	 * @notice Claim bounty
	 * @param _user address of recipient
	 * @param _execute true if it's actual execution
	 * @return issueBaseBounty true for base bounty
	 */
	function claimBounty(uint32 _chainEid, address _user, bool _execute) public onlyMainChain returns (bool issueBaseBounty) {
		if (msg.sender != address(bountyManager)) revert BountyOnly();
		issueBaseBounty = !isEligibleForRewards(_user, _chainEid);
	}

	/**
	 * @dev Send PRFI rewards to user.
	 * @param _user address of recipient
	 * @param _amount of PRFI
	 */
	function _sendPrime(address _user, uint256 _amount) internal {
		if (_amount == 0) {
			return;
		}
		uint256 chefReserve = IERC20(_prfiToken).balanceOf(address(this));
		require(_amount <= chefReserve, OutOfRewards());
		IERC20(_prfiToken).safeTransfer(_user, _amount);
	}

	/**
	 * @notice Pause the claim operations.
	 */
	function pause() external onlyOwner {
		_pause();
	}

	/**
	 * @notice Unpause the claim operations.
	 */
	function unpause() external onlyOwner {
		_unpause();
	}

	/**
	 * @notice Returns the amount of PRFI that can be claimed by a user
	 * @param _user The address of the user
	 * @param _chainEid The ID of the chain
	 * @return The amount of PRFI that can be claimed by the user
	 */
	function userBaseClaimable(address _user, uint32 _chainEid) public view returns (uint256) {
		return earned(_user, _chainEid);
		
	}

	/**
	 * @notice Returns the amount of rewards per second
	 * @return The amount of rewards per second in PRFI token units
	 */
	function rewardsPerSecond() public view returns (uint256) {
		return prfiPerSecond;
	}

	/**
	 * @dev Update the given pool's allocation point. Can only be called by the owner.
	 * @param _tokens for reward pools
	 * @param _allocPoints allocation points of the pools
	 */
	function batchUpdateAllocPoint(address[] calldata _tokens, uint256[] calldata _allocPoints) external onlyOwner {
		require(_tokens.length == _allocPoints.length, InvalidLength());
		uint256 _totalAllocPoint = totalAllocPoint;
		uint256 length = _tokens.length;

		/// @dev Update alloc points for each pool
		for (uint256 i; i < length; ) {
			PoolInfo storage pool = poolInfo[_tokens[i]];
			require(pool.lastRewardTime != 0, UnknownPool());
			_totalAllocPoint = _totalAllocPoint.sub(pool.allocPoint).add(_allocPoints[i]);
			pool.allocPoint = _allocPoints[i];
			unchecked {
				i++;
			}
		}
		totalAllocPoint = _totalAllocPoint;
		emit BatchAllocPointsUpdated(_tokens, _allocPoints);
	}

	/**
     * @notice Sets the peer address (OApp instance) for a corresponding endpoint.
     * @param _eid The endpoint ID.
     * @param _peer The address of the peer to be associated with the corresponding endpoint.
     *
     * @dev Only the owner/admin of the OApp can call this function.
     * @dev Indicates that the peer is trusted to send LayerZero messages to this OApp.
     * @dev Set this to bytes32(0) to remove the peer address.
     * @dev Peer is a bytes32 to accommodate non-evm chains.
     */
    function setPeer(uint32 _eid, bytes32 _peer) public override onlyOwner {
		if (_isMainChain) {
			require(_eid != _mainChain, InvalidChain());
			if (_peer != bytes32(0)) {
				_sidechains.add(_eid);
			} else {
				require(_sidechains.contains(_eid), InvalidChain());
				_sidechains.remove(_eid);
			}
		} else {
			require(_eid == _mainChain, InvalidChain());
		}

        _setPeer(_eid, _peer);
    }
}
