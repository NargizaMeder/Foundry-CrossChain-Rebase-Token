//SPDX-Licence-Indetifier: MIT
pragma solidity ^0.8.24;

import {IRebaseToken} from "./interfaces/IRebaseToken.sol";

contract Vault {
    //Core Requirements:
    //1. Store the address of the RebaseToken contract (passed in constructor)
    //2. Implement a deposit function:
    //      - Accepts ETH from a user
    //      - Mints RebaseToken to the user, equivalent to the ETH sent (1:1)
    // 3. IMplement Redeem function:
    //  - Burns the user's RebaseToken
    //   - Sneds the corresponding amount of the Eth back to the usser
    // 4. Implement a mechanism to add ETH rewards to the vault.

    IRebaseToken private immutable i_rebaseToken; // Interface type

    event Deposit(address indexed user, uint256 amount);
    event Redeem(address indexed user, uint256 amount);

    error Vault__RedeemFailed();
    error Vault__DepositAmountIsZero();

    constructor(IRebaseToken _rebaseTokenAddress) {
        i_rebaseToken = _rebaseTokenAddress;
    }

    /**
     * @notice Gets the address of the RebaseToken contract associated with this vault
     * @return THe address of the RebaseToken
     */

    function getRebaseTokenAddress() external view returns (address) {
        return address(i_rebaseToken); //Cast to address to return
    }

    /**
     *  @notice Fallback function to accept ETH rewards sent directly to the contract
     *  @dev ANy ETH sent to this contract's address without data will be accepted
     */
    receive() external payable {}

    /**
     *  @notice Allows a user to deposit ETH and receive an eqiova;ent amount of RebaseTokens
     *  @dev The amount of ETH sent with the transaction(msg.value) determines the amount of tokens minted.
     *  Assumes a 1:1 peg for ETH to RebaseTOken for simplicity in this version
     */
    function deposit() external payable {
        //The amount of ETH sent is msg.value
        //The user making the call is msg.sender
        uint256 amountToMint = msg.value;

        //ENsure some ETH is actually sent
        if (amountToMint == 0) {
            revert Vault__DepositAmountIsZero();
        }

        //Call the mint function on the RebaseToken contract
        i_rebaseToken.mint(msg.sender, msg.value, i_rebaseToken.getInterestRate());
        emit Deposit(msg.sender, amountToMint);
    }

    /**
     * @notice Allows a user to burn their RebaseToken and receive a correspoding amount of ETH.
     * @param _amount The amount of RebaseTokens to redeem
     * @dev Follows CEI pattern. Uses low-level call .call for ETH transfer
     */
    function redeem(uint256 _amount) external {
        uint256 amountToRedeem = _amount; //Use a new variable to store the actual redeem amount
        if (_amount == type(uint256).max) {
            amountToRedeem = i_rebaseToken.balanceOf(msg.sender);
        }
        //1. Effects (State cahnges occurs first)
        //Burn the specified amount of tokens from the caller(msg.sender)
        //The RebaseToken's burn function should handle checks for sufficient balance.
        i_rebaseToken.burn(msg.sender, _amount);

        //2.Interacttions (External calls/ETH transfer last)
        //Send the equivalent amount of ETH back to the user
        (bool success,) = payable(msg.sender).call{value: _amount}("");

        //Check if the ETH transfer succeeded
        if (!success) {
            revert Vault__RedeemFailed();
        }

        emit Redeem(msg.sender, _amount);
    }
}
