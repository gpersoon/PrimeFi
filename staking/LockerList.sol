// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AddressPagination} from "../libraries/AddressPagination.sol";

/// @title Locker List Contract
/// @author Prime
contract LockerList is Ownable {
	using AddressPagination for address[];

	/// @notice List of lockers
	address[] internal userList;

	/// @notice Mapping of user to index
	mapping(address => uint256) internal indexOf;

	/// @notice Mapping of user to inserted status
	mapping(address => bool) internal inserted;

	/********************** Events ***********************/

	/// @notice Emitted when a locker is added
	event LockerAdded(address indexed locker);

	/// @notice Emitted when a locker is removed
	event LockerRemoved(address indexed locker);

	/********************** Errors ***********************/

	/// @notice Error message emitted when the user is not eligible
	error Ineligible();

	/********************** Lockers list ***********************/

	constructor() Ownable(_msgSender()) {}

	/**
	 * @notice Return the number of users.
	 * @return count The number of users
	 */
	function lockersCount() external view returns (uint256 count) {
		count = userList.length;
	}

	/**
	 * @notice Return the list of users.
	 * @dev This is a very gas intensive function to execute and thus should only by utilized by off-chain entities.
	 * @param page The page number to retrieve
	 * @param limit The number of entries per page
	 * @return users A paginated list of users
	 */
	function getUsers(uint256 page, uint256 limit) external view returns (address[] memory users) {
		users = userList.paginate(page, limit);
	}

	/**
	 * @notice Add a locker.
	 * @dev This can be called only by the owner. Owner should be MFD contract.
	 * @param user address to be added
	 */
	function addToList(address user) external onlyOwner {
		if (inserted[user] == false) {
			inserted[user] = true;
			indexOf[user] = userList.length;
			userList.push(user);
		}

		emit LockerAdded(user);
	}

	/**
	 * @notice Remove a locker.
	 * @dev This can be called only by the owner. Owner should be MFD contract.
	 * @param user address to remove
	 */
	function removeFromList(address user) external onlyOwner {
		if (inserted[user] == false) revert Ineligible();

		delete inserted[user];

		uint256 index = indexOf[user];
		uint256 lastIndex = userList.length - 1;
		address lastUser = userList[lastIndex];

		indexOf[lastUser] = index;
		delete indexOf[user];

		userList[index] = lastUser;
		userList.pop();

		emit LockerRemoved(user);
	}
}
