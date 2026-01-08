// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockWrappedNative} from "test/mocks/MockWrappedNative.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address deployer;
        address treasuryAddress;
        address wrappedNativeToken;
        uint256 loanFeeBps;
        uint256 minLoanDuration;
        uint256 maxLoanDuration;
        uint256 minInterestRateBps;
        uint256 maxInterestRateBps;
        uint256 batchLimit;
    }

    NetworkConfig public activeNetworkConfig;

    constructor() {
        if (block.chainid == 999) {
            activeNetworkConfig = getHyperEvmConfig();
        } else {
            activeNetworkConfig = getAnvilConfig();
        }
    }

    function getAnvilConfig() public returns (NetworkConfig memory) {
        MockWrappedNative mockWrappedNative = new MockWrappedNative();

        return NetworkConfig({
            deployer: vm.envAddress("DEFAULT_ANVIL_DEPLOYER"), // Change to your deployer address
            treasuryAddress: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8, // Change to your treasury address
            wrappedNativeToken: address(mockWrappedNative),
            loanFeeBps: 100, // 5% loan fee
            minLoanDuration: 1 days,
            maxLoanDuration: 365 days,
            minInterestRateBps: 100, // 1% interest
            maxInterestRateBps: 30000, // 300% interest
            batchLimit: 10
        });
    }

    function getHyperEvmConfig() public view returns (NetworkConfig memory) {
        return NetworkConfig({
            deployer: vm.envAddress("DEFAULT_ANVIL_DEPLOYER"), // Change to your deployer address
            treasuryAddress: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8, // Change to your treasury address
            wrappedNativeToken: 0x5555555555555555555555555555555555555555,
            loanFeeBps: 100, // 5% loan fee
            minLoanDuration: 1 days,
            maxLoanDuration: 365 days,
            minInterestRateBps: 100, // 1% interest
            maxInterestRateBps: 30000, // 300% interest
            batchLimit: 10
        });
    }
}
