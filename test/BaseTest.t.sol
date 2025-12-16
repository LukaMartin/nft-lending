// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {NFTLending} from "src/NFTLending.sol";
import {Test} from "forge-std/Test.sol";
import {MockERC721} from "test/mocks/mockERC721.sol";
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
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");
    address dave = makeAddr("dave");
    address eve = makeAddr("eve");
    address deployer;

    // Init variables
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
        vm.label(alice, "alice");
        vm.deal(payable(alice), DEFAULT_ETH_BALANCE);

        vm.label(bob, "bob");
        vm.deal(payable(bob), DEFAULT_ETH_BALANCE);

        vm.label(charlie, "charlie");
        vm.deal(payable(charlie), DEFAULT_ETH_BALANCE);

        vm.label(dave, "dave");
        vm.deal(payable(dave), DEFAULT_ETH_BALANCE);

        vm.label(eve, "eve");
        vm.deal(payable(eve), DEFAULT_ETH_BALANCE);

        vm.label(deployer, "deployer");
        vm.deal(payable(deployer), DEFAULT_ETH_BALANCE);
    }
}
