// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {NFTLending} from "src/NFTLending.sol";
import {Test} from "forge-std/Test.sol";
import {MockERC721} from "test/mocks/MockERC721.sol";
import {MockWrappedNative} from "test/mocks/MockWrappedNative.sol";
import {DeployNFTLending} from "script/DeployNFTLending.s.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";

contract BaseTest is Test {
    // Contracts
    NFTLending nftLending;
    DeployNFTLending nftLendingDeployer;
    MockERC721 mockERC721One;
    MockERC721 mockERC721Two;
    MockWrappedNative mockWrappedNative;
    HelperConfig helperConfig;

    // ERC721 addresses
    address mockERC721OneAddress;
    address mockERC721TwoAddress;

    // User addresses
    address immutable ALICE = makeAddr("alice");
    address immutable BOB = makeAddr("bob");
    address immutable CHARLIE = makeAddr("charlie");
    address immutable DAVE = makeAddr("dave");
    address immutable EVE = makeAddr("eve");

    // Init variables
    address deployer;
    address treasury;
    address wrappedNativeToken;
    uint256 loanFeeBps;
    uint256 minLoanDuration;
    uint256 maxLoanDuration;
    uint256 minInterestRateBps;
    uint256 maxInterestRateBps;
    uint256 batchLimit;

    // Default ETH balance
    uint256 public constant DEFAULT_ETH_BALANCE = 100 ether;

    // RPC
    uint256 hyperEvmFork;

    function setUp() public virtual {
        // Create fork
        hyperEvmFork = vm.createSelectFork("hyperevm");
        assertEq(vm.activeFork(), hyperEvmFork);

        // Create mock ERC721 contracts
        mockERC721One = new MockERC721();
        mockERC721Two = new MockERC721();

        // Set addresses
        mockERC721OneAddress = address(mockERC721One);
        mockERC721TwoAddress = address(mockERC721Two);

        // Deploy NFTLending contract
        nftLendingDeployer = new DeployNFTLending();
        (nftLending, helperConfig) = nftLendingDeployer.run();
        (
            deployer,
            treasury,
            wrappedNativeToken,
            loanFeeBps,
            minLoanDuration,
            maxLoanDuration,
            minInterestRateBps,
            maxInterestRateBps,
            batchLimit
        ) = helperConfig.activeNetworkConfig();

        // Create mock WHype contract
        deployCodeTo("MockWrappedNative.sol", wrappedNativeToken);
        mockWrappedNative = MockWrappedNative(payable(wrappedNativeToken));

        // Fund users
        _fundUsers();
    }

    function _fundUsers() internal {
        vm.label(ALICE, "ALICE");
        vm.deal(payable(ALICE), DEFAULT_ETH_BALANCE);

        vm.label(BOB, "BOB");
        vm.deal(payable(BOB), DEFAULT_ETH_BALANCE);

        vm.label(CHARLIE, "CHARLIE");
        vm.deal(payable(CHARLIE), DEFAULT_ETH_BALANCE);

        vm.label(DAVE, "DAVE");
        vm.deal(payable(DAVE), DEFAULT_ETH_BALANCE);

        vm.label(EVE, "EVE");
        vm.deal(payable(EVE), DEFAULT_ETH_BALANCE);

        vm.label(deployer, "DEPLOYER");
        vm.deal(payable(deployer), DEFAULT_ETH_BALANCE);
    }
}
