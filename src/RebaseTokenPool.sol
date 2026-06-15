//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TokenPool} from "@ccip/pools/TokenPool.sol";
import {FinalityCodec} from "@ccip/libraries/FinalityCodec.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRebaseToken} from "./interfaces/IRebaseToken.sol";
import {Pool} from "@ccip/libraries/Pool.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract RebaseTokenPool is TokenPool {
    constructor(IERC20 token, address advancedPoolHooks, address rmnProxy, address router)
        TokenPool(token, 18, advancedPoolHooks, rmnProxy, router)
    {}

    //@notice burns the tokens on the source chain
    function lockOrBurn(Pool.LockOrBurnInV1 calldata lockOrBurnIn)
        public
        override
        returns (Pool.LockOrBurnOutV1 memory lockOrBurnOut)
    {
        _validateLockOrBurn(lockOrBurnIn, FinalityCodec.WAIT_FOR_FINALITY_FLAG, "", 0);

        uint256 userInterestRate = IRebaseToken(address(i_token)).getUserInterestRate(lockOrBurnIn.originalSender);

        IRebaseToken(address(i_token)).burn(address(this), lockOrBurnIn.amount);

        lockOrBurnOut = Pool.LockOrBurnOutV1({
            destTokenAddress: getRemoteToken(lockOrBurnIn.remoteChainSelector),
            destPoolData: abi.encode(userInterestRate)
        });
    }

    function releaseOrMint(Pool.ReleaseOrMintInV1 calldata releaseOrMintIn, bytes4 requestedFinalityConfig)
        public
        override
        returns (Pool.ReleaseOrMintOutV1 memory)
    {
        _validateReleaseOrMint(releaseOrMintIn, releaseOrMintIn.sourceDenominatedAmount, requestedFinalityConfig);

        address receiver = releaseOrMintIn.receiver;

        (uint256 userInterestRate) = abi.decode(releaseOrMintIn.sourcePoolData, (uint256));

        //Mint rebasing tokens to the receiver on the destinantion chain
        //This will also mint any interest rate  that has accrued since the last time the user's balance was updated
        IRebaseToken(address(i_token)).mint(receiver, releaseOrMintIn.sourceDenominatedAmount, userInterestRate);

        return Pool.ReleaseOrMintOutV1({destinationAmount: releaseOrMintIn.sourceDenominatedAmount});
    }
}
