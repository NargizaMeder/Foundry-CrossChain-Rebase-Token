//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {RebaseToken} from "../src/RebaseToken.sol";
import {RebaseTokenPool} from "../src/RebaseTokenPool.sol";
import {Vault} from "../src/Vault.sol";
import {IRebaseToken} from "../src/interfaces/IRebaseToken.sol";

import {CCIPLocalSimulatorFork, Register} from "@chainlink-local/ccip/CCIPLocalSimulatorFork.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RegistryModuleOwnerCustom} from "@ccip/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
import {TokenAdminRegistry} from "@ccip/tokenAdminRegistry/TokenAdminRegistry.sol";
import {RateLimiter} from "@ccip/libraries/RateLimiter.sol";
import {Client} from "@ccip/libraries/Client.sol";
import {IRouterClient} from "@ccip/interfaces/IRouterClient.sol";
import {TokenPool} from "@ccip/pools/TokenPool.sol";

contract CrossChainTest is Test {
    uint256 sepoliaFork;
    uint256 arbSepoliaFork;
    uint256 public SEND_VALUE = 1e5;
    CCIPLocalSimulatorFork ccipLocalSimulatorFork;

    RebaseToken sepoliaToken;
    RebaseToken arbSepoliaToken;
    Vault vault; // Vault will only be on the source chain(Sepolia)

    RebaseTokenPool sepoliaPool;
    RebaseTokenPool arbSepoliaPool;

    TokenAdminRegistry tokenAdminRegistrySepolia;
    TokenAdminRegistry tokenAdminRegistryArbSepolia;

    Register.NetworkDetails sepoliaNetworkDetails;
    Register.NetworkDetails arbSepoliaNetworkDetails;

    RegistryModuleOwnerCustom registryModuleOwnerCustomSepolia;
    RegistryModuleOwnerCustom registryModuleOwnerCustomArbSepolia;

    address public owner = makeAddr("owner");
    address user = makeAddr("user");

    function setUp() public {
        //1. Create and select the initial /source fork -Sepolia
        //This uses the sepolia alias defined in foundry.toml
        sepoliaFork = vm.createSelectFork("sepolia");

        //2. Create the destinantion fork - Arbitrum Sepolia - but dont select it yet
        arbSepoliaFork = vm.createFork("arb-sepolia");

        //3. Deploy the CCIPLocalSimulatorFork contract on the source fork (Sepolia)
        ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();

        //4.Make the simulator's address persistent across all active forks
        //This is crucial so both the Sepolia and Arbitrum forks
        //can interact with the same instance of the simulator contract
        vm.makePersistent(address(ccipLocalSimulatorFork));

        //Get both network details before fork-specific setup
        sepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);

        vm.selectFork(arbSepoliaFork);
        arbSepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);

        //Sepolia setup
        vm.selectFork(sepoliaFork);
        vm.startPrank(owner);
        sepoliaToken = new RebaseToken();

        sepoliaPool = new RebaseTokenPool(
            IERC20(address(sepoliaToken)),
            address(0),
            sepoliaNetworkDetails.rmnProxyAddress,
            sepoliaNetworkDetails.routerAddress
        );

        vault = new Vault(IRebaseToken(address(sepoliaToken))); //Pass the Sepolia token address, cast to IRebaseToken interface
        vm.deal(address(vault), 1e18);

        sepoliaToken.grantMintAndBurnRole(address(sepoliaPool));
        sepoliaToken.grantMintAndBurnRole(address(vault));

        registryModuleOwnerCustomSepolia =
            RegistryModuleOwnerCustom(sepoliaNetworkDetails.registryModuleOwnerCustomAddress);
        registryModuleOwnerCustomSepolia.registerAdminViaOwner(address(sepoliaToken));
        tokenAdminRegistrySepolia = TokenAdminRegistry(sepoliaNetworkDetails.tokenAdminRegistryAddress);
        tokenAdminRegistrySepolia.acceptAdminRole(address(sepoliaToken));
        tokenAdminRegistrySepolia.setPool(address(sepoliaToken), address(sepoliaPool));

        vm.stopPrank();

        //Arbitrum Sepolia setup
        vm.selectFork(arbSepoliaFork);
        vm.startPrank(owner);

        arbSepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);

        arbSepoliaToken = new RebaseToken();

        arbSepoliaPool = new RebaseTokenPool(
            IERC20(address(arbSepoliaToken)),
            address(0),
            arbSepoliaNetworkDetails.rmnProxyAddress,
            arbSepoliaNetworkDetails.routerAddress
        );

        arbSepoliaToken.grantMintAndBurnRole(address(arbSepoliaPool));

        registryModuleOwnerCustomArbSepolia =
            RegistryModuleOwnerCustom(arbSepoliaNetworkDetails.registryModuleOwnerCustomAddress);
        registryModuleOwnerCustomArbSepolia.registerAdminViaOwner(address(arbSepoliaToken));
        tokenAdminRegistryArbSepolia = TokenAdminRegistry(arbSepoliaNetworkDetails.tokenAdminRegistryAddress);
        tokenAdminRegistryArbSepolia.acceptAdminRole(address(arbSepoliaToken));
        tokenAdminRegistryArbSepolia.setPool(address(arbSepoliaToken), address(arbSepoliaPool));

        vm.stopPrank();
    }

    function configureTokenPool(
        uint256 fork,
        TokenPool localPool,
        TokenPool remotePool,
        IRebaseToken remoteToken,
        Register.NetworkDetails memory remoteNetworkDetails
    ) public {
        vm.selectFork(fork);
        vm.startPrank(owner);
        TokenPool.ChainUpdate[] memory chains = new TokenPool.ChainUpdate[](1);
        bytes[] memory remotePoolAddresses = new bytes[](1);
        remotePoolAddresses[0] = abi.encode(address(remotePool));
        chains[0] = TokenPool.ChainUpdate({
            remoteChainSelector: remoteNetworkDetails.chainSelector,
            remotePoolAddresses: remotePoolAddresses,
            remoteTokenAddress: abi.encode(address(remoteToken)),
            outboundRateLimiterConfig: RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0}),
            inboundRateLimiterConfig: RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0})
        });
        uint64[] memory remoteChainSelectorsToRemove = new uint64[](0);
        localPool.applyChainUpdates(remoteChainSelectorsToRemove, chains);
        vm.stopPrank();
    }

    function bridgeTokens(
        uint256 amountToBridge,
        uint256 localFork, //Source chain fork ID
        uint256 remoteFork, //Destination chain fork ID
        Register.NetworkDetails memory localNetworkDetails, //Struct with source chain info
        Register.NetworkDetails memory remoteNetworkDetails, // Struct with dest.chain info
        RebaseToken localToken, //Source token contract instance
        RebaseToken remoteToken
    ) public {
        vm.selectFork(localFork);
        vm.startPrank(user);
        //1. Initialize tokenAmounts array
        Client.EVMTokenAmount[] memory tokenToSendDetails = new Client.EVMTokenAmount[](1);
        Client.EVMTokenAmount memory tokenAmount =
            Client.EVMTokenAmount({token: address(localToken), amount: amountToBridge});
        tokenToSendDetails[0] = tokenAmount;
        //Approve the router to burn tokens on users behalf
        IERC20(address(localToken)).approve(localNetworkDetails.routerAddress, amountToBridge);

        //2. Construct the EVM2AnyMessage
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(user), //receiver on the destinantion chain
            data: "",
            tokenAmounts: tokenToSendDetails, // The token and amounts to transfer
            feeToken: localNetworkDetails.linkAddress, // Using LINK as fee token
            extraArgs: ""
        });
        vm.stopPrank();

        //3. Get CCIP fee
        uint256 fee =
            IRouterClient(localNetworkDetails.routerAddress).getFee(remoteNetworkDetails.chainSelector, message);

        //4. Fund the user with LINK (for testing via CCIPlocalsimulatorfork)
        //This step is specific to the local simulator
        ccipLocalSimulatorFork.requestLinkFromFaucet(user, fee);

        //5. Approve LINK for the Router
        vm.startPrank(user);
        IERC20(localNetworkDetails.linkAddress).approve(localNetworkDetails.routerAddress, fee);

        //6. Approve the actual token to be bridged
        vm.startPrank(user);
        IERC20(localNetworkDetails.linkAddress).approve(localNetworkDetails.routerAddress, fee);

        //7. Get user's balance on the local chain BEFORE sending
        uint256 localBalanceBefore = IERC20(address(localToken)).balanceOf(user);
        console.log("Local balance before bridge: ", localBalanceBefore);

        //8. Send the CCIP message
        IRouterClient(localNetworkDetails.routerAddress).ccipSend(remoteNetworkDetails.chainSelector, message);

        //9. Get user's balance on the local chain AFTER sending and assert
        uint256 localBalanceAfter = IERC20(address(localToken)).balanceOf(user);
        console.log("Local balance after bridge: ", localBalanceAfter);
        assertEq(localBalanceAfter, localBalanceBefore - amountToBridge, "Local balance incorrect after send");
        vm.stopPrank();

        vm.selectFork(remoteFork);
        //10. Simulate message propagation to the remote chain
        vm.warp(block.timestamp + 20 minutes);

        //11. Get user's balance on the remote chain BEFORE message proccesing
        uint256 remoteBalanceBefore = IERC20(address(remoteToken)).balanceOf(user);

        vm.selectFork(localFork);
        //12. Process the message on the remote chain(using CCIPLocalSimulatorFork)
        ccipLocalSimulatorFork.switchChainAndRouteMessage(remoteFork);

        //13. Get user's balance on the remote chain AFTER message processing and assert
        uint256 remoteBalanceAfter = IERC20(address(remoteToken)).balanceOf(user);
        assertEq(remoteBalanceAfter, remoteBalanceBefore + amountToBridge, "Remote balance incorrect after receive");

        //14. Check Interest rate (specific to Rebasetoken logic)
        //IMPORTANT: localUserInterestRate should be fetched before switching to remoteFork
        vm.selectFork(localFork);
        uint256 localUserInterestRate = localToken.getInterestRate();
        vm.selectFork(remoteFork);
        uint256 remoteUserInterestRate = remoteToken.getUserInterestRate(user);
        assertEq(remoteUserInterestRate, localUserInterestRate, "Interest rates do not match");
    }

    function testBridgeAllTokens() public {
        uint256 DEPOSIT_AMOUNT = 1e5; //Using a small, fixed amount for clarity

        configureTokenPool(
            sepoliaFork, sepoliaPool, arbSepoliaPool, IRebaseToken(address(arbSepoliaToken)), arbSepoliaNetworkDetails
        );
        configureTokenPool(
            arbSepoliaFork, arbSepoliaPool, sepoliaPool, IRebaseToken(address(sepoliaToken)), sepoliaNetworkDetails
        );

        //1. Deposit into Vault on Sepolia
        vm.selectFork(sepoliaFork);
        vm.deal(user, DEPOSIT_AMOUNT); //Give user some amount ETH to deposit

        vm.startPrank(user);
        //To send ETH with a contract call in foundry
        //Cast contract instance to address, then to payable, then back to contract type
        Vault(payable(address(vault))).deposit{value: DEPOSIT_AMOUNT}();

        uint256 startBalance = IERC20(address(sepoliaToken)).balanceOf(user);

        assertEq(startBalance, DEPOSIT_AMOUNT, "User token balance after deposit incorrect");
        vm.stopPrank();

        //2. Bridge tokens: Sepolia -> Arbitrum Sepolia
        bridgeTokens(
            DEPOSIT_AMOUNT,
            sepoliaFork,
            arbSepoliaFork,
            sepoliaNetworkDetails,
            arbSepoliaNetworkDetails,
            sepoliaToken,
            arbSepoliaToken
        );

        //Bridge All TOkens Back : Arbitrum -> Sepolia
        vm.selectFork(arbSepoliaFork);
        vm.warp(block.timestamp + 3600);
        uint256 destBalance = IERC20(address(arbSepoliaToken)).balanceOf(user);

        bridgeTokens(
            destBalance,
            arbSepoliaFork,
            sepoliaFork,
            arbSepoliaNetworkDetails,
            sepoliaNetworkDetails,
            arbSepoliaToken,
            sepoliaToken
        );
    }

    function testBridgeTwice() public {
        configureTokenPool(
            sepoliaFork, sepoliaPool, arbSepoliaPool, IRebaseToken(address(arbSepoliaToken)), arbSepoliaNetworkDetails
        );
        configureTokenPool(
            arbSepoliaFork, arbSepoliaPool, sepoliaPool, IRebaseToken(address(sepoliaToken)), sepoliaNetworkDetails
        );

        vm.selectFork(sepoliaFork);
        vm.deal(user, SEND_VALUE);
        vm.startPrank(user);
        Vault(payable(address(vault))).deposit{value: SEND_VALUE}();
        uint256 startBalance = IERC20(address(sepoliaToken)).balanceOf(user);
        assertEq(startBalance, SEND_VALUE);
        vm.stopPrank();

        //Bridge half tokens to the destination chain
        console.log("Bridging tokens (first bridging event)", SEND_VALUE / 2);
        bridgeTokens(
            SEND_VALUE / 2,
            sepoliaFork,
            arbSepoliaFork,
            sepoliaNetworkDetails,
            arbSepoliaNetworkDetails,
            sepoliaToken,
            arbSepoliaToken
        );

        //wait for 1 hour for the interest to accrue
        vm.selectFork(sepoliaFork);
        vm.warp(block.timestamp + 3600);
        uint256 newSourceBalance = IERC20(address(sepoliaToken)).balanceOf(user);
        //bridge tokens
        console.log("Bridging tokens - second event", newSourceBalance);
        bridgeTokens(
            newSourceBalance,
            sepoliaFork,
            arbSepoliaFork,
            sepoliaNetworkDetails,
            arbSepoliaNetworkDetails,
            sepoliaToken,
            arbSepoliaToken
        );

        //bridge back ALL TOKENS to the source chain after 1 hour
        vm.selectFork(arbSepoliaFork);
        vm.warp(block.timestamp + 3600);
        uint256 destBalance = IERC20(address(arbSepoliaToken)).balanceOf(user);
        bridgeTokens(
            destBalance,
            arbSepoliaFork,
            sepoliaFork,
            arbSepoliaNetworkDetails,
            sepoliaNetworkDetails,
            arbSepoliaToken,
            sepoliaToken
        );
    }
}
