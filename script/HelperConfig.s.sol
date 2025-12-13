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
            deployer: vm.envAddress("DEFAULT_ANVIL_DEPLOYER"),
            treasuryAddress: 0x0920b96EF597b3a5cEB7994482ADa8b368D8cAD9,
            wrappedNativeToken: address(mockWrappedNative),
            loanFeeBps: 500, // 5% loan fee
            minLoanDuration: 1 days,
            maxLoanDuration: 30 days,
            minInterestRateBps: 100, // 1% interest
            maxInterestRateBps: 30000, // 300% interest
            batchLimit: 8
        });
    }

    function getHyperEvmConfig() public view returns (NetworkConfig memory) {
        return NetworkConfig({
            deployer: vm.envAddress("DEFAULT_ANVIL_DEPLOYER"),
            treasuryAddress: 0x0920b96EF597b3a5cEB7994482ADa8b368D8cAD9,
            wrappedNativeToken: 0x5555555555555555555555555555555555555555,
            loanFeeBps: 500, // 5% loan fee
            minLoanDuration: 1 days,
            maxLoanDuration: 30 days,
            minInterestRateBps: 100, // 1% interest
            maxInterestRateBps: 30000, // 300% interest
            batchLimit: 8
        });
    }
}
