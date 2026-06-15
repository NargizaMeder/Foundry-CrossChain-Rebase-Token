//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title RebaseToken
 * @notice This is a cross-chain rebase token that incentivises users to deposit into a vault and gain interrest in rewards
 * @notice THe interest rate in the smart contract can only decrease.
 * @notice Each user will have their own interest rate that is the global rate at the time of deposit
 *
 */

contract RebaseToken is ERC20, Ownable, AccessControl {
    error RebaseToken__InterestRateCanOnlyDecrease(uint256 oldInterestRate, uint256 newInterestRate);

    /////////////////////
    // State Variables
    /////////////////////

    uint256 private s_interestRate = 5e10;
    uint256 private constant PRECISION_FACTOR = 1e18;
    bytes32 private constant MINT_AND_BURN_ROLE = keccak256("MINT_AND_BURN_ROLE");

    mapping(address => uint256) private s_userInterestRate;
    mapping(address => uint256) private s_userLastUpdatedTimestamp;

    /////////////////////
    // Events////////////
    /////////////////////

    event InterestRateSet(uint256 newInterestRate);

    /////////////////////
    // Constructor //////
    /////////////////////

    constructor() ERC20("Rebase Token", "RBT") Ownable(msg.sender) {}

    /////////////////////
    // Functions ///////
    /////////////////////

    function grantMintAndBurnRole(address _account) external onlyOwner {
        _grantRole(MINT_AND_BURN_ROLE, _account);
    }

    /**
     * @notice Set the global interest rate for the contract
     * @param _newInterestRate The new interest rate to set scaled by precsion factor basis points per second
     * @dev The interest rate can only decrease. Access control(OnlyOwner) should be added
     */
    function setInterestRate(uint256 _newInterestRate) external onlyOwner {
        if (_newInterestRate >= s_interestRate) {
            revert RebaseToken__InterestRateCanOnlyDecrease(s_interestRate, _newInterestRate);
        }
        s_interestRate = _newInterestRate;
        emit InterestRateSet(_newInterestRate);
    }

    /**
     * @notice Mints tokens to a user, typically upon deposits
     * @dev Also mints accrued interest and locks in the current Global rate for the user
     * @param _to The address to mint tokens to
     * @param _amount THe principal amount of tokens to mint
     */
    function mint(address _to, uint256 _amount, uint256 _userInterestRate) public onlyRole(MINT_AND_BURN_ROLE) {
        //ToDO add access control (OnlyVault)
        _mintAccruedInterest(_to); // 1. Mint any existing accrued interest for the user

        //2. Update the user's interest rate for future calculations if necessary
        //This assumes s_interestRate is the current global rate
        //If the user already has a deposit, their rate might be updated
        s_userInterestRate[_to] = _userInterestRate;

        //3. Mint the newly deposited amount
        _mint(_to, _amount);
    }

    /**
     * @notice Burn the users tokens,e.g. when they withdraw from a vault or from cross-chain transfers
     * Handles burning the Entire balance if _amount is type(uint256).max
     * @param _from The user address from which to burn tokens
     * @param _amount The amount of tokens to burn. Use type(uint256).max to burn all tokens.
     */
    function burn(address _from, uint256 _amount) public onlyRole(MINT_AND_BURN_ROLE) {
        uint256 currentTotalBalance = balanceOf(_from); //Calculate this one for efficiency if needed for checks

        if (_amount == type(uint256).max) {
            _amount = currentTotalBalance; //Set amount to full current balance
        }

        //Ensure _amount doesnt exceed actual balance after potential interest accrual
        //This check is important especially if _amount wasnt type(uint256).max
        //_mintAccruedInterest will update the super.balanceOf(_from)
        //So after _mintAccruedInterest super.balanceOf(_from) should be currentTotalBalance
        //The ERC20 _burn function will typically revert if _amount > super.balanceOf(_from)

        _mintAccruedInterest(_from); //MInt any accrued interest first

        //At this point super.balance(_from) reflects the balance including all interest up to now
        //If _amount was type(uint256).max , then _amount == super.balanceOf(_from)
        //If _amount was specific, super.balanceOf(_from) must be >= _amount for _burn to succeed

        _burn(_from, _amount);
    }

    /**
     * @notice Returns the current balance of an account, including accrued interest
     * @param _user The address of the account
     * @return The total balance including interest
     */
    function balanceOf(address _user) public view override returns (uint256) {
        //Get the user's stored principal balance(tokens actually minted to them)
        uint256 principalBalance = super.balanceOf(_user);
        if (principalBalance == 0) {
            return 0;
        }

        //Calculate the growth factor to the principal balance
        uint256 growthFactor = _calculateUserAccumulatedInterestSinceLastUpdate(_user);

        //Apply the growth factor to the principal balance
        // Remember PRECISION_FACTOR is used for scaling, so we divide by it here.

        return (principalBalance * growthFactor) / PRECISION_FACTOR;
    }

    /**
     * @notice Transfers tokens from the caller to a recipient
     * Accrued interest for both sender and recipient is MInted before the Transfer
     * If the recipient is new, they inherit the sender's interest rate
     * @param _recipient The address to transfer tokens to
     * @param _amount The amount of tokens to tranfer. Can be type(uint256).max to transfer full balance
     * @return A boolean indicating whether the operation succeeded.
     */
    function transfer(address _recipient, uint256 _amount) public override returns (bool) {
        //1. Mint accrued interest rate for both sender and recipient
        _mintAccruedInterest(msg.sender);
        _mintAccruedInterest(_recipient);

        //2. handle request to transfer maximum balance
        if (_amount == type(uint256).max) {
            _amount = balanceOf(msg.sender); //Use the interest -inclusive balance
        }

        //3. Set recipient's interest rate if they are new (balance is checked before super.balanceOf)
        //We use balanceOf here to check the effective balance including any just minted interest
        //If _mintAccruedInterest made their balance non-zero, but they had 0 principle, this still means are "new" for raye setting
        // A more robust check for 'newness' for rate settting might be super.balanceOf(_recipient) == 0 before any interest minting for the recipient
        //However, the current logic is: if their 'effective" balance is 0 before the main transfer part, they get the sender's rate
        if (balanceOf(_recipient) == 0 && _amount > 0) {
            s_userInterestRate[_recipient] = s_userInterestRate[msg.sender];
        }

        //4. Execute the base ERC20 transfer
        return super.transfer(_recipient, _amount);
    }

    /**
     * @notice Transfers tokens from one address to another, on Behalf of the sender,
     * provided in allowance is in place.
     * Accrued interest for both sender and recipient is minted before the transfer.
     * If the recipient is new, they inherit the sender's interest rate.
     */
    function transferFrom(address _sender, address _recipient, uint256 _amount) public override returns (bool) {
        //1. Mint accrued interest rate for both sender and recipient
        _mintAccruedInterest(_sender);
        _mintAccruedInterest(_recipient);

        //2. handle request to transfer maximum balance
        if (_amount == type(uint256).max) {
            _amount = balanceOf(_sender); //Use the interest -inclusive balance
        }

        if (balanceOf(_recipient) == 0 && _amount > 0) {
            s_userInterestRate[_recipient] = s_userInterestRate[_sender];
        }

        return super.transferFrom(_sender, _recipient, _amount);
    }

    /**
     * @notice Gets the principle balance of a user (tokens actually minted to them), excluding any accrued interest
     */
    function principleBalanceOf(address _user) external view returns (uint256) {
        return super.balanceOf(_user); //calls ERC20.balanceOf
    }

    /////Internal Functions//////

    /**
     * @notice Mint the accrued interest to the user since the last time they interacted with the protocol(burn, mint,transfer)
     * @dev Internal function to calculate and mint accrued interest for a user
     * @dev Updates the user's last updated timestamp
     * @param _user The user to mint the accrued interest to
     */
    function _mintAccruedInterest(address _user) internal {
        //TODO Implement full logic to calculate and mint actual interest tokens.

        //1. find their current balance of rebase tokens that have been minted to the user -> principal balance
        uint256 previousPrincipleBalance = super.balanceOf(_user);

        //2. Calculate their current balance including any interest - > balanceOf
        uint256 currentBalance = balanceOf(_user);

        //calculate the number of tokens that need to be minted to the user-> 2-1
        uint256 balanceIncrease = currentBalance - previousPrincipleBalance;

        //set the users last updated timestamp (Effect)
        s_userLastUpdatedTimestamp[_user] = block.timestamp;

        //Mint the accrued interest (Interaction)
        if (balanceIncrease > 0) {
            //Optimization: only mint if therre's interest
            _mint(_user, balanceIncrease);
        }
    }

    function _calculateUserAccumulatedInterestSinceLastUpdate(address _user)
        internal
        view
        returns (uint256 linearInterestFactor)
    {
        //1. Calculate the time elapsed since the user/s balance was last effectively updated
        uint256 timeElapsed = block.timestamp - s_userLastUpdatedTimestamp[_user];

        //If no time has passed, or if the user has no locked rate(e.g never interacted),
        //the growth factor is simply 1
        if (timeElapsed == 0 || s_userInterestRate[_user] == 0) {
            return PRECISION_FACTOR;
        }

        // 2. Calculate the total fractional interest accrued: UserInterestRate*TimeElapsed
        // s_userInterestRate[_user] is the rate per second
        uint256 fractionalInterest = s_userInterestRate[_user] * timeElapsed;

        //3. The growth factor is (1 + fractional_interest_part)
        //Since 1 is represented as PRECISION_FACTOR, and fractionalINterest is already scaled, we add them
        linearInterestFactor = PRECISION_FACTOR + fractionalInterest;
        return linearInterestFactor;
    }

    /////Public Functions//////

    function getInterestRate() external view returns (uint256) {
        return s_interestRate;
    }

    function getUserInterestRate(address _user) external view returns (uint256) {
        return s_userInterestRate[_user];
    }

    function setUserInterestRate(address _user, uint256 _rate) external onlyRole(MINT_AND_BURN_ROLE) {
        s_userInterestRate[_user] = _rate;
    }
}
