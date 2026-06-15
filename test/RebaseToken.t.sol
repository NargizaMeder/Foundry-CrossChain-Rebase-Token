//SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {RebaseToken} from "../src/RebaseToken.sol";
import {Vault} from "../src/Vault.sol";
import {IRebaseToken} from "../src/interfaces/IRebaseToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract RebaseTokenTest is Test {
    RebaseToken public rebaseToken;
    Vault public vault;

    address public owner = makeAddr("owner");
    address public user = makeAddr("user");
    uint256 SEND_VALUE = 1e5;

    function setUp() public {
        //Impersonate the owner assress for deployments and role granting
        vm.startPrank(owner);

        rebaseToken = new RebaseToken();

        //Deploy Vault: requires IRebaseToken
        //Direct casting(IRebaseToken(rebaseToken)) is invalid
        //Correct way: cast rebaseToken to address, then to IRebaseTOken
        vault = new Vault(IRebaseToken(address(rebaseToken)));

        //Grant the MINT_AND_BURN_ROLE to the Vaul contract
        rebaseToken.grantMintAndBurnRole(address(vault));

        vm.stopPrank();
    }

    function addRewardsToVault(uint256 rewardAmount) public {
        //Send 1 ETH to the Vault to simulate initial funds
        //The target address must be cast to 'payable'
        payable(address(vault)).call{value: rewardAmount}("");
    }

    //Test if interest accrues linearly after a deposit
    //'amount' will be a fuzzed input
    function testDepositLinear(uint256 amount) public {
        //Constrain the fuzzed 'amount' to a practical range
        //Min: 0.000001(1e5 wei) , MAX: type(uint96).max to avoid overflows
        amount = bound(amount, 1e5, type(uint96).max);

        //1. User deposits amount ETH
        vm.startPrank(user);
        vm.deal(user, amount);

        vault.deposit{value: amount}();

        //2. Check initial rebase token balance for user
        uint256 initialBalance = rebaseToken.balanceOf(user);
        console.log("block.timestamp", block.timestamp);
        console.log("startBalance", initialBalance);
        assertEq(initialBalance, amount);

        //3. Warp time forward and check balance again
        uint256 timeDelta = 1 hours;
        vm.warp(block.timestamp + timeDelta);
        uint256 middlebBalance = rebaseToken.balanceOf(user);
        assertGt(middlebBalance, initialBalance);

        //4. Warp time forward by the same amount and check balance again
        vm.warp(block.timestamp + timeDelta);
        uint256 endBalance = rebaseToken.balanceOf(user);
        assertGt(endBalance, middlebBalance);

        assertApproxEqAbs(endBalance - middlebBalance, middlebBalance - initialBalance, 1);

        vm.stopPrank();
    }

    function testRedeemsStraightAway(uint256 amount) public {
        amount = bound(amount, 1e5, type(uint96).max);
        //Deposit funds
        vm.startPrank(user);
        vm.deal(user, amount);
        vault.deposit{value: amount}();

        //Redeem funds
        vault.redeem(amount);

        uint256 balance = rebaseToken.balanceOf(user);
        assertEq(balance, 0);
        vm.stopPrank();
    }

    function testRedeemAfterTimeHasPassed(uint256 depositAmount, uint256 time) public {
        time = bound(time, 1000, type(uint96).max); //this is a crazy number of years
        depositAmount = bound(depositAmount, 1e5, type(uint96).max);

        vm.deal(user, depositAmount);
        vm.prank(user);
        vault.deposit{value: depositAmount}();

        //check the balance has increased after some time has passed
        vm.warp(time);

        //Get balance after time has passed
        uint256 balance = rebaseToken.balanceOf(user);

        //Add rewards to the vault
        vm.deal(owner, balance - depositAmount);
        vm.prank(owner);
        addRewardsToVault(balance - depositAmount);

        //Redeem funds
        vm.prank(user);
        vault.redeem(balance);

        uint256 ethBalance = address(user).balance;

        assertEq(ethBalance, balance);
        assertGt(balance, depositAmount);
    }

    function testRedeemMoreThanBalanceReverts(uint256 amount) public {
        amount = bound(amount, 1e5, type(uint96).max);

        vm.startPrank(user);
        vm.deal(user, amount);

        vault.deposit{value: amount}();

        uint256 redeemAmount = amount + 1e3;

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user, amount, redeemAmount)
        );

        vault.redeem(redeemAmount);

        vm.stopPrank();
    }

    function testTransfer(uint256 amount, uint256 amountToSend) public {
        amount = bound(amount, 1e5 + 1e3, type(uint96).max);
        amountToSend = bound(amountToSend, 1e5, amount - 1e3);

        //Deposit funds
        vm.deal(user, amount);
        vm.prank(user);
        vault.deposit{value: amount}();

        //Transfer some rebase tokens to another address
        address recipient = makeAddr("recipient");
        uint256 senderBalance = rebaseToken.balanceOf(user);
        uint256 recipientBalance = rebaseToken.balanceOf(recipient);

        assertEq(senderBalance, amount);
        assertEq(recipientBalance, 0);

        //Update the interest rate so we can check the user interest rates are different after the transfer
        vm.prank(owner);
        rebaseToken.setInterestRate(4e10);

        //Send half the balance to the another user
        vm.prank(user);
        rebaseToken.transfer(recipient, amountToSend);
        uint256 senderBalanceAfterTransfer = rebaseToken.balanceOf(user);
        uint256 recipientBalanceAfterTransfer = rebaseToken.balanceOf(recipient);
        assertEq(senderBalanceAfterTransfer, senderBalance - amountToSend);
        assertEq(recipientBalanceAfterTransfer, recipientBalance + amountToSend);

        //After some time has passed, check the balance of the two users has increased
        vm.warp(block.timestamp + 1 days);
        uint256 senderBalanceAfterWarp = rebaseToken.balanceOf(user);
        uint256 recipientBalanceAfterWarp = rebaseToken.balanceOf(recipient);
        //check the interest rates are as expected after the transfer
        //since the recipient hadnt minted before, his interest rate should be the same as the sender
        uint256 recipientInterestRate = rebaseToken.getUserInterestRate(recipient);
        assertEq(recipientInterestRate, 5e10);

        uint256 senderInterestRate = rebaseToken.getUserInterestRate(user);
        assertEq(senderInterestRate, 5e10);

        assertGt(senderBalanceAfterWarp, senderBalanceAfterTransfer);
        assertGt(recipientBalanceAfterWarp, recipientBalanceAfterTransfer);
    }

    function testCannotCallMint() public {
        //Deposit funds
        vm.startPrank(user);
        uint256 interestRate = rebaseToken.getInterestRate();
        vm.expectRevert();
        rebaseToken.mint(user, 1e5, interestRate);
        vm.stopPrank();
    }

    function testCannotCallBurn() public {
        //Deposit funds
        vm.startPrank(user);
        vm.expectRevert();
        rebaseToken.burn(user, 1e5);
        vm.stopPrank();
    }

    function testCannotWithdrawMoreThanBalance() public {
        vm.startPrank(user);
        vm.deal(user, SEND_VALUE);
        vault.deposit{value: SEND_VALUE}();
        vm.expectRevert();
        vault.redeem(SEND_VALUE + 1e3);
        vm.stopPrank();
    }

    function testDeposit(uint256 amount) public {
        amount = bound(amount, 1e3, type(uint96).max);
        vm.deal(user, amount);
        vm.prank(user);
        vault.deposit{value: amount}();

        uint256 balance = rebaseToken.balanceOf(user);
        assertEq(balance, amount);
    }

    function testDepositAmountCannotBeZero() public {
        vm.prank(user);
        vm.expectRevert(Vault.Vault__DepositAmountIsZero.selector);
        vault.deposit{value: 0}();
    }

    function testSetInterestRate(uint256 newInterestRate) public {
        //Constrain the fuzzed 'newInterestRate' to a practical range
        //Min: 0% (0) , Max: 100% (1e11 in ray)
        newInterestRate = bound(newInterestRate, 0, rebaseToken.getInterestRate() - 1);

        vm.startPrank(owner);
        rebaseToken.setInterestRate(newInterestRate);

        uint256 currentInterestRate = rebaseToken.getInterestRate();
        assertEq(currentInterestRate, newInterestRate);
        vm.stopPrank();

        //check if someone deposits, this is their new interest rate
        vm.startPrank(user);
        vm.deal(user, 1e5);
        vault.deposit{value: 1e5}();
        uint256 userInterestRate = rebaseToken.getUserInterestRate(user);
        vm.stopPrank();
        assertEq(userInterestRate, newInterestRate);
    }

    function testCannotSetInterestRate(uint256 newInterestRate) public {
        vm.startPrank(user);
        vm.expectRevert();
        rebaseToken.setInterestRate(newInterestRate);
        vm.stopPrank();
    }

    function testInterestRateCanOnlyDecrease(uint256 newInterestRate) public {
        uint256 initialInterestRate = rebaseToken.getInterestRate();
        //Constrain the fuzzed 'newInterestRate' to a practical range
        newInterestRate = bound(newInterestRate, initialInterestRate, type(uint96).max);

        vm.prank(owner);
        vm.expectPartialRevert(bytes4(RebaseToken.RebaseToken__InterestRateCanOnlyDecrease.selector));
        rebaseToken.setInterestRate(newInterestRate);
        assertEq(rebaseToken.getInterestRate(), initialInterestRate);
    }

    function testGetPrincipleAmount() public {
        vm.deal(user, SEND_VALUE);
        vm.prank(user);
        vault.deposit{value: SEND_VALUE}();
        uint256 principleAmount = rebaseToken.principleBalanceOf(user);
        assertEq(principleAmount, SEND_VALUE);

        //After some time has passed, check the principle amount is still the same
        vm.warp(block.timestamp + 1 days);
        uint256 principleAmountAfterWarp = rebaseToken.principleBalanceOf(user);
        assertEq(principleAmountAfterWarp, SEND_VALUE);
    }
}
