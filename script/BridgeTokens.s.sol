//SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {IRouterClient} from "@ccip/interfaces/IRouterClient.sol";
import {Client} from "@ccip/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BridgeTokenScript is Script {
    function run(
        address receiverAddress,
        uint64 destinationChainSelector,
        address tokenToSendAddress, //Address of the ERC20 token being bridged
        uint256 amountToSend,
        address linkTokenAddress,
        address routerAddress //Address of the CCIP Router on the source chain
    ) public {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: tokenToSendAddress, //The address of the token being sent
            amount: amountToSend
        });

        vm.startBroadcast();
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(receiverAddress),
            data: "", //Empty bytes as we are sending no data payload
            tokenAmounts: tokenAmounts,
            feeToken: linkTokenAddress,
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: 0}))
        });

        //Cast routerAddress to IRouterClient to call its functions
        uint256 ccipFee = IRouterClient(routerAddress).getFee(destinationChainSelector, message);

        //Approve the CCIP Router to spend the fee token (LINK)
        IERC20(linkTokenAddress).approve(routerAddress, ccipFee);

        //Approve the CCIP Router to spend the token being bridged
        IERC20(tokenToSendAddress).approve(routerAddress, amountToSend);

        //Call ccipSend on the router
        IRouterClient(routerAddress).ccipSend(destinationChainSelector, message);

        vm.stopBroadcast();
    }
}
