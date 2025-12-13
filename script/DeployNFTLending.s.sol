// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {NFTLending} from "src/NFTLending.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";

contract DeployNFTLending is Script {
    HelperConfig public helperConfig;
    NFTLending public nftLending;

    function run() external returns (NFTLending, HelperConfig) {
        helperConfig = new HelperConfig();
        (
            address deployer,
            address treasuryAddress,
            address wrappedNativeToken,
            uint256 loanFeeBps,
            uint256 minLoanDuration,
            uint256 maxLoanDuration,
            uint256 minInterestRateBps,
            uint256 maxInterestRateBps,
            uint256 batchLimit
        ) = helperConfig.activeNetworkConfig();

        vm.startBroadcast(deployer);

        nftLending = new NFTLending(
            treasuryAddress,
            wrappedNativeToken,
            loanFeeBps,
            minLoanDuration,
            maxLoanDuration,
            minInterestRateBps,
            maxInterestRateBps,
            batchLimit
        );

        vm.stopBroadcast();

        return (nftLending, helperConfig);
    }
}
