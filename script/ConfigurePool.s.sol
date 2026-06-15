//SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {TokenPool} from "@ccip/pools/TokenPool.sol";
import {RateLimiter} from "@ccip/libraries/RateLimiter.sol";

contract ConfigurePoolScript is Script {
    function run(
        address localPool,
        uint64 remoteChainSelector,
        address remotePool,
        address remoteToken,
        bool outboundRateLimiterIsEnabled,
        uint128 outboundRateLimiterCapacity,
        uint128 outboundRateLimiterRate,
        bool inboundRateLimiterIsEnabled,
        uint128 inboundRateLimiterCapacity,
        uint128 inboundRateLimiterRate
    ) public {
        vm.startBroadcast();
        //Prepare remotePoolAddresses (needs to be bytes[])
        bytes[] memory remotePoolAddresses_ = new bytes[](1);
        remotePoolAddresses_[0] = abi.encode(remotePool);

        //Prepare remoteTokenAddresses to be bytes
        bytes memory remoteTokenAddresses_ = abi.encode(remoteToken);

        TokenPool.ChainUpdate[] memory chainsToAdd = new TokenPool.ChainUpdate[](1);

        chainsToAdd[0] = TokenPool.ChainUpdate({
            remoteChainSelector: remoteChainSelector,
            remotePoolAddresses: remotePoolAddresses_,
            remoteTokenAddress: remoteTokenAddresses_,
            outboundRateLimiterConfig: RateLimiter.Config({
                isEnabled: outboundRateLimiterIsEnabled,
                capacity: outboundRateLimiterCapacity,
                rate: outboundRateLimiterRate
            }),
            inboundRateLimiterConfig: RateLimiter.Config({
                isEnabled: inboundRateLimiterIsEnabled,
                capacity: inboundRateLimiterCapacity,
                rate: inboundRateLimiterRate
            })
        });

        //Cast localPool address to TokenPool contract type
        TokenPool(localPool).applyChainUpdates(new uint64[](0), chainsToAdd);

        vm.stopBroadcast();
    }
}
