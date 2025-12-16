// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {NFTLending} from "src/NFTLending.sol";
import {BaseTest} from "./BaseTest.t.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract NFTLendingTest is BaseTest {
    // Variables
    uint96 public constant DEFAULT_PRINCIPAL = 1 ether;
    uint32 public constant DEFAULT_INTEREST_RATE_BPS = 10000;
    uint64 public constant DEFAULT_DURATION = 30 days;
    uint64 public constant DEFAULT_OFFER_EXPIRY = 7 days;

    // Events
    event LoanOfferCreated(
        uint256 offerId, address indexed lender, address indexed nftCollection, uint256 interestRate, uint64 loanDuration, uint64 offerExpiry
    );

    function setUp() public virtual override {
        BaseTest.setUp();
        _setUserNFTBalances();
        _whitelistCollections();
    }

    function _setUserNFTBalances() internal {
        // Set user NFT balances
        mockERC721One.setTokenId(Alice, 1);
        mockERC721One.setTokenId(Alice, 2);
        mockERC721One.setTokenId(Alice, 3);
        mockERC721Two.setTokenId(Bob, 1);
        mockERC721Two.setTokenId(Bob, 2);
        mockERC721Two.setTokenId(Bob, 3);

        // Assertions
        assertEq(mockERC721One.balanceOf(Alice), 3);
        assertEq(mockERC721Two.balanceOf(Bob), 3);

        // Set approvals
        vm.prank(Alice);
        mockERC721One.setApprovalForAll(address(nftLending), true);

        vm.prank(Bob);
        mockERC721Two.setApprovalForAll(address(nftLending), true);
    }

    function _whitelistCollections() internal {
        // Whitelist default mock collections
        vm.startPrank(Deployer);
        nftLending.setCollectionWhitelisted(address(mockERC721One), true);
        nftLending.setCollectionWhitelisted(address(mockERC721Two), true);
        vm.stopPrank();
    }

    function _createLoanOffer(address nftCollection, uint96 principal, uint32 interestRateBps, uint64 loanDuration, uint64 offerExpiry)
        internal
        returns (uint256)
    {
        vm.startPrank(Alice);
        // Deposit wrapped native, and approve NFTLending to spend
        mockWrappedNative.deposit{value: principal}();
        mockWrappedNative.approve(address(nftLending), principal);

        // Create loan offer
        uint256 loanOfferId = nftLending.createLoanOffer(address(nftCollection), principal, interestRateBps, loanDuration, offerExpiry);
        vm.stopPrank();

        return loanOfferId;
    }

    function _setupBatchLoanOffers(uint256 numOffers, address nftCollection)
        internal
        returns (uint256[] memory, uint96[] memory, uint32[] memory, uint64[] memory, uint64[] memory, uint256[] memory)
    {
        uint96[] memory principalAmounts = new uint96[](numOffers);
        uint32[] memory interestRatesBps = new uint32[](numOffers);
        uint64[] memory loanDurations = new uint64[](numOffers);
        uint64[] memory offerExpiries = new uint64[](numOffers);
        uint256[] memory interestAmounts = new uint256[](numOffers);
        for (uint256 i = 0; i < numOffers; i++) {
            principalAmounts[i] = uint96(bound(vm.randomUint(), 0.01 ether, 10 ether));
            interestRatesBps[i] = uint32(bound(vm.randomUint(), minInterestRateBps, maxInterestRateBps));
            loanDurations[i] = uint64(bound(vm.randomUint(), minLoanDuration, maxLoanDuration));
            offerExpiries[i] = uint64(block.timestamp + loanDurations[i]);
        }

        // Create loan offers
        vm.prank(Alice);
        uint256[] memory loanOfferIds =
            nftLending.batchCreateLoanOffers(nftCollection, principalAmounts, interestRatesBps, loanDurations, offerExpiries);

        for (uint256 i = 0; i < numOffers; i++) {
            interestAmounts[i] = _getInterest(principalAmounts[i], interestRatesBps[i], loanDurations[i]);
        }

        return (loanOfferIds, principalAmounts, interestRatesBps, loanDurations, offerExpiries, interestAmounts);
    }

    function _acceptBatchLoanOffers(uint256[] memory loanOfferIds)
        internal
        returns (uint256[] memory)
    {
        uint256[] memory tokenIds = new uint256[](loanOfferIds.length);
        for (uint256 i = 0; i < loanOfferIds.length; i++) {
            tokenIds[i] = i + 1;
        }

        vm.prank(Bob);
        uint256[] memory loanIds = nftLending.batchAcceptLoanOffers(loanOfferIds, tokenIds);

        return loanIds;
    }

    function _getInterest(uint256 principal, uint256 interestRateBps, uint256 duration)
        internal
        pure
        returns (uint256)
    {
        return (principal * interestRateBps * duration) / (10000 * 365 days);
    }

    function _getFee(uint256 interest) internal view returns (uint256) {
        return (interest * loanFeeBps) / 10000;
    }

    /* Create Loan Offer Tests */

    function testCreateLoanOfferRevertsWhenDurationIsLessThanMinDuration() public {
        // Initialize variables
        uint64 duration = 0.5 days; // Min duration is 1 day, attempt to create offer with 0.5 days
        uint64 offerExpiry = uint64(block.timestamp + duration);

        // Create loan offer with duration less than min duration
        vm.startPrank(Alice);
        mockWrappedNative.deposit{value: DEFAULT_PRINCIPAL}();
        mockWrappedNative.approve(address(nftLending), DEFAULT_PRINCIPAL);
        vm.expectRevert(NFTLending.InvalidDuration.selector);
        nftLending.createLoanOffer(address(mockERC721One), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, duration, offerExpiry);
        vm.stopPrank();
    }

    function testCreateLoanOfferRevertsWhenInterestRateIsLessThanMinInterestRate() public {
        // Initialize variables
        uint32 interestRateBps = 99; // Min interest rate is 100 bps, attempt to create offer with 99 bps
        uint64 offerExpiry = uint64(block.timestamp + DEFAULT_OFFER_EXPIRY);

        // Create loan offer with interest rate less than min interest rate
        vm.startPrank(Alice);
        mockWrappedNative.deposit{value: DEFAULT_PRINCIPAL}();
        mockWrappedNative.approve(address(nftLending), DEFAULT_PRINCIPAL);
        vm.expectRevert(NFTLending.InvalidInterestRate.selector);
        nftLending.createLoanOffer(address(mockERC721One), DEFAULT_PRINCIPAL, interestRateBps, DEFAULT_DURATION, offerExpiry);
        vm.stopPrank();
    }

    function testCreateLoanOfferRevertsWhenInterestRateIsGreaterThanMaxInterestRate() public {
        // Initialize variables
        uint32 interestRateBps = 30001; // Max interest rate is 30000 bps, attempt to create offer with 30001 bps
        uint64 offerExpiry = uint64(block.timestamp + DEFAULT_OFFER_EXPIRY);

        // Create loan offer with interest rate greater than max interest rate
        vm.startPrank(Alice);
        mockWrappedNative.deposit{value: DEFAULT_PRINCIPAL}();
        mockWrappedNative.approve(address(nftLending), DEFAULT_PRINCIPAL);
        vm.expectRevert(NFTLending.InvalidInterestRate.selector);
        nftLending.createLoanOffer(address(mockERC721One), DEFAULT_PRINCIPAL, interestRateBps, DEFAULT_DURATION, offerExpiry);
        vm.stopPrank();
    }

    function testCreateLoanOfferRevertsWhenDurationIsGreaterThanMaxDuration() public {
        // Initialize variables
        uint64 duration = 30 days + 1 seconds; // Max duration is 30 days
        uint64 offerExpiry = uint64(block.timestamp + duration);

        // Create loan offer with duration greater than max duration
        vm.startPrank(Alice);
        mockWrappedNative.deposit{value: DEFAULT_PRINCIPAL}();
        mockWrappedNative.approve(address(nftLending), DEFAULT_PRINCIPAL);
        vm.expectRevert(NFTLending.InvalidDuration.selector);
        nftLending.createLoanOffer(address(mockERC721One), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, duration, offerExpiry);
        vm.stopPrank();
    }

    function testCreateLoanOfferRevertsWhenOfferExpiryIsInThePast() public {
        // Initialize variables
        uint64 offerExpiry = uint64(block.timestamp - 1 seconds);

        // Create loan offer with offer expiry in the past
        vm.startPrank(Alice);
        mockWrappedNative.deposit{value: DEFAULT_PRINCIPAL}();
        mockWrappedNative.approve(address(nftLending), DEFAULT_PRINCIPAL);
        vm.expectRevert(abi.encodeWithSelector(NFTLending.InvalidOfferExpiry.selector, offerExpiry, block.timestamp));
        nftLending.createLoanOffer(address(mockERC721One), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry);
        vm.stopPrank();
    }

    function testCreateLoanOfferRevertsWhenCollectionIsNotWhitelisted() public {
        // Initialize variables
        address nftCollection = address(0);
        uint64 offerExpiry = uint64(block.timestamp + DEFAULT_OFFER_EXPIRY);

        // Create loan offer with collection not whitelisted
        vm.startPrank(Alice);
        mockWrappedNative.deposit{value: DEFAULT_PRINCIPAL}();
        mockWrappedNative.approve(address(nftLending), DEFAULT_PRINCIPAL);
        vm.expectRevert(abi.encodeWithSelector(NFTLending.CollectionNotWhitelisted.selector, nftCollection));
        nftLending.createLoanOffer(nftCollection, DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry);
        vm.stopPrank();
    }

    function testCreateLoanOfferIncrementsNextOfferId() public {
        // Initialize variables
        uint256 nextOfferId = nftLending.getLoanOfferCount();
        uint64 offerExpiry = uint64(block.timestamp + DEFAULT_OFFER_EXPIRY);

        // Create loan offer
        _createLoanOffer(address(mockERC721One), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry);

        // Assertions
        assertEq(nftLending.getLoanOfferCount(), nextOfferId + 1);
    }

    function testCreateLoanOfferAndAssertLoanOfferDetails() public {
        // Get current loan offer count
        uint256 loanOfferCount = nftLending.getLoanOfferCount();
        uint64 offerExpiry = uint64(block.timestamp + DEFAULT_OFFER_EXPIRY);

        // Create loan offer
        uint256 loanOfferId =
            _createLoanOffer(address(mockERC721One), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry);

        // Get loan offer
        NFTLending.LoanOffer memory loanOffer = nftLending.getLoanOffer(loanOfferId);

        // Assertions
        assertEq(loanOfferCount, loanOfferId);
        assertEq(loanOffer.lender, Alice);
        assertEq(loanOffer.nftCollection, address(mockERC721One));
        assertEq(loanOffer.principal, DEFAULT_PRINCIPAL);
        assertEq(loanOffer.interestRateBps, DEFAULT_INTEREST_RATE_BPS);
        assertEq(loanOffer.loanDuration, DEFAULT_DURATION);
        assertEq(loanOffer.offerExpiry, offerExpiry);
        assertEq(loanOffer.active, true);
    }

    function testCreateLoanOfferEmitsLoanOfferCreatedEvent() public {
        // Initialize variables
        uint256 loanOfferId = nftLending.getLoanOfferCount();
        uint64 offerExpiry = uint64(block.timestamp + DEFAULT_OFFER_EXPIRY);

        // Create loan offer
        vm.startPrank(Alice);
        mockWrappedNative.deposit{value: DEFAULT_PRINCIPAL}();
        mockWrappedNative.approve(address(nftLending), DEFAULT_PRINCIPAL);
        vm.expectEmit(true, true, true, true);
        emit LoanOfferCreated(loanOfferId, Alice, address(mockERC721One), DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry);
        nftLending.createLoanOffer(
            address(mockERC721One), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );
        vm.stopPrank();
    }

    function testAcceptLoanOfferRevertsWhenOfferIsInactive() public {
        // Initialize variables
        uint256 tokenId = 1;
        uint64 offerExpiry = uint64(block.timestamp + DEFAULT_OFFER_EXPIRY);

        // Create loan offer
        uint256 loanOfferId =
            _createLoanOffer(address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry);

        // Accept loan offer
        vm.prank(Bob);
        nftLending.acceptLoanOffer(loanOfferId, tokenId);

        // Try to accept loan offer again
        vm.prank(Bob);
        vm.expectRevert(NFTLending.OfferInactive.selector);
        nftLending.acceptLoanOffer(loanOfferId, tokenId);
    }

    function testAcceptLoanOfferRevertsWhenOfferIsExpired() public {
        // Initialize variables
        uint64 offerExpiry = uint64(block.timestamp + DEFAULT_OFFER_EXPIRY);
        uint256 tokenId = 1;

        // Create loan offer
        uint256 loanOfferId =
            _createLoanOffer(address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry);

        // Warp to offer expiry + 1 second
        vm.warp(offerExpiry + 1 seconds);

        // Try to accept loan offer
        vm.prank(Bob);
        vm.expectRevert(NFTLending.OfferExpired.selector);
        nftLending.acceptLoanOffer(loanOfferId, tokenId);
    }

    function testAcceptLoanOffer() public {
        // Initialize variables
        uint64 offerExpiry = uint64(block.timestamp + DEFAULT_OFFER_EXPIRY);

        // Create loan offer
        uint256 loanOfferId =
            _createLoanOffer(address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry);

        // Loan details
        uint256 tokenId = 1;

        // Accept loan offer
        vm.prank(Bob);
        nftLending.acceptLoanOffer(loanOfferId, tokenId);
    }

    function testCancelLoanOffer() public {
        // Initialize variables
        uint64 offerExpiry = uint64(block.timestamp + DEFAULT_OFFER_EXPIRY);
        
        // Create loan offer
        uint256 loanOfferId =
            _createLoanOffer(address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry);

        // Cancel loan offer
        vm.prank(Alice);
        nftLending.cancelLoanOffer(loanOfferId);
    }

    // function test_cancelLoanOffer() public {
    //     (uint256 loanOfferId, uint256 principal, uint256 interestRateBps, uint256 duration, uint256 interest) =
    //         _setupLoanOffer(address(mockERC721One));

    //     // Cancel loan offer
    //     vm.prank(Alice);
    //     hySwapLending.cancelLoanOffer(loanOfferId);

    //     // Get loan offer
    //     HySwapLending.LoanOffer memory loanOffer = hySwapLending.getLoanOffer(loanOfferId);

    //     // Assertions
    //     assertEq(hySwapLending.getLoanOfferCount(), 1);
    //     assertEq(hySwapLending.getLoanCount(), 0);
    //     assertEq(loanOffer.active, false);
    //     assertEq(loanOffer.lender, Alice);
    //     assertEq(loanOffer.nftCollection, address(mockERC721One));
    //     assertEq(loanOffer.principal, principal);
    //     assertEq(loanOffer.interestRateBps, interestRateBps);
    //     assertEq(loanOffer.interest, interest);
    //     assertEq(loanOffer.duration, duration);
    // }

    // function test_repayLoan() public {
    //     // Get pre-treasury balance
    //     uint256 preTreasuryBalance = treasuryAddress.balance;

    //     // Get Alice pre-loan balance
    //     uint256 preAliceBalance = Alice.balance;

    //     // Create loan offer
    //     (uint256 loanOfferId, uint256 principal,,, uint256 interest) = _setupLoanOffer(address(mockERC721Two));

    //     // Accept loan offer
    //     vm.prank(Bob);
    //     uint256 loanId = hySwapLending.acceptLoanOffer(loanOfferId, address(mockERC721Two), 1);

    //     // Skip 29 days
    //     skip(29 days);

    //     // Get fee
    //     uint256 fee = _getFee(interest);

    //     // Repay loan
    //     vm.prank(Bob);
    //     hySwapLending.repayLoan{value: principal + interest + fee}(loanId);

    //     // Get loan
    //     HySwapLending.Loan memory loan = hySwapLending.getLoanDetails(loanId);

    //     // Assertions
    //     assertEq(loan.repaid, true);
    //     assertEq(loan.borrower, Bob);
    //     assertEq(loan.lender, Alice);
    //     assertEq(loan.nftCollection, address(mockERC721Two));
    //     assertEq(loan.tokenId, 1);
    //     assertEq(loan.principal, principal);
    //     assertEq(loan.interest, interest);
    //     assertEq(loan.fee, fee);
    //     assertEq(loan.collateralClaimed, false);
    //     assertEq(Alice.balance, preAliceBalance + interest);
    //     assertEq(treasuryAddress.balance, preTreasuryBalance + fee);
    //     assertEq(mockERC721Two.balanceOf(address(hySwapLending)), 0);
    //     assertEq(mockERC721Two.balanceOf(Bob), 3);
    // }

    // function test_claimCollateral() public {
    //     (uint256 loanOfferId, uint256 principal,,,) = _setupLoanOffer(address(mockERC721Two));

    //     // Accept loan offer
    //     vm.prank(Bob);
    //     uint256 loanId = hySwapLending.acceptLoanOffer(loanOfferId, address(mockERC721Two), 1);

    //     // Skip just over 30 days
    //     skip(30 days + 1 seconds);

    //     // Claim collateral
    //     vm.prank(Alice);
    //     hySwapLending.claimCollateral(loanId);

    //     // Get loan
    //     HySwapLending.Loan memory loan = hySwapLending.getLoanDetails(loanId);

    //     // Assertions
    //     assertEq(mockERC721Two.balanceOf(address(hySwapLending)), 0);
    //     assertEq(mockERC721Two.balanceOf(Alice), 1);
    //     assertEq(mockERC721Two.balanceOf(Bob), 2);
    //     assertEq(mockERC721Two.ownerOf(1), Alice);
    //     assertEq(loan.collateralClaimed, true);
    //     assertEq(loan.repaid, false);
    //     assertEq(loan.borrower, Bob);
    //     assertEq(loan.lender, Alice);
    //     assertEq(loan.nftCollection, address(mockERC721Two));
    //     assertEq(loan.tokenId, 1);
    //     assertEq(loan.principal, principal);
    // }

    // function test_batchCreateLoanOffers() public {
    //     uint256 numOffers = 3;

    //     (
    //         uint256[] memory loanOfferIds,
    //         uint96[] memory principalAmounts,
    //         uint32[] memory interestRatesBps,
    //         uint64[] memory durations,
    //         uint256[] memory interestAmounts
    //     ) = _setupBatchLoanOffers(numOffers, address(mockERC721One));

    //     // Get loan offers
    //     HySwapLending.LoanOffer memory loanOfferOne = hySwapLending.getLoanOffer(loanOfferIds[0]);
    //     HySwapLending.LoanOffer memory loanOfferTwo = hySwapLending.getLoanOffer(loanOfferIds[1]);
    //     HySwapLending.LoanOffer memory loanOfferThree = hySwapLending.getLoanOffer(loanOfferIds[2]);

    //     // Assertions
    //     assertEq(hySwapLending.getLoanOfferCount(), numOffers);
    //     assertEq(loanOfferOne.lender, Alice);
    //     assertEq(loanOfferOne.nftCollection, address(mockERC721One));
    //     assertEq(loanOfferOne.principal, principalAmounts[0]);
    //     assertEq(loanOfferOne.interestRateBps, interestRatesBps[0]);
    //     assertEq(loanOfferOne.interest, interestAmounts[0]);
    //     assertEq(loanOfferOne.duration, durations[0]);

    //     assertEq(loanOfferTwo.lender, Alice);
    //     assertEq(loanOfferTwo.nftCollection, address(mockERC721One));
    //     assertEq(loanOfferTwo.principal, principalAmounts[1]);
    //     assertEq(loanOfferTwo.interestRateBps, interestRatesBps[1]);
    //     assertEq(loanOfferTwo.interest, interestAmounts[1]);
    //     assertEq(loanOfferTwo.duration, durations[1]);

    //     assertEq(loanOfferThree.lender, Alice);
    //     assertEq(loanOfferThree.nftCollection, address(mockERC721One));
    //     assertEq(loanOfferThree.principal, principalAmounts[2]);
    //     assertEq(loanOfferThree.interestRateBps, interestRatesBps[2]);
    //     assertEq(loanOfferThree.interest, interestAmounts[2]);
    //     assertEq(loanOfferThree.duration, durations[2]);
    // }

    // function test_batchAcceptLoanOffers_offerStates() public {
    //     uint256 numOffers = 3;

    //     // Get loan offers
    //     (uint256[] memory loanOfferIds,,,,) = _setupBatchLoanOffers(numOffers, address(mockERC721Two));

    //     // Accept loans
    //     _acceptBatchLoanOffers(loanOfferIds, address(mockERC721Two));

    //     HySwapLending.LoanOffer memory loanOfferOne = hySwapLending.getLoanOffer(loanOfferIds[0]);
    //     HySwapLending.LoanOffer memory loanOfferTwo = hySwapLending.getLoanOffer(loanOfferIds[1]);
    //     HySwapLending.LoanOffer memory loanOfferThree = hySwapLending.getLoanOffer(loanOfferIds[2]);

    //     // Assertions
    //     assertEq(hySwapLending.getLoanOfferCount(), 3);
    //     assertEq(loanOfferOne.active, false);
    //     assertEq(loanOfferTwo.active, false);
    //     assertEq(loanOfferThree.active, false);
    // }

    // function test_batchAcceptLoanOffers_loanStates() public {
    //     uint256 numOffers = 3;

    //     // Setup loan offers
    //     (uint256[] memory loanOfferIds,,,,) = _setupBatchLoanOffers(numOffers, address(mockERC721Two));

    //     // Accept loans
    //     uint256[] memory loanIds = _acceptBatchLoanOffers(loanOfferIds, address(mockERC721Two));

    //     // Get loan details
    //     HySwapLending.Loan memory loanOne = hySwapLending.getLoanDetails(loanIds[0]);
    //     HySwapLending.Loan memory loanTwo = hySwapLending.getLoanDetails(loanIds[1]);
    //     HySwapLending.Loan memory loanThree = hySwapLending.getLoanDetails(loanIds[2]);

    //     // Assertions
    //     assertEq(hySwapLending.getLoanCount(), 3);
    //     assertEq(loanOne.repaid, false);
    //     assertEq(loanTwo.repaid, false);
    //     assertEq(loanThree.repaid, false);
    // }

    // function test_batchAcceptLoanOffers_loanDetails() public {
    //     uint256 numOffers = 3;

    //     // Get loan offers
    //     (uint256[] memory loanOfferIds, uint96[] memory principalAmounts,,, uint256[] memory interestAmounts) =
    //         _setupBatchLoanOffers(numOffers, address(mockERC721Two));

    //     // Accept loans
    //     uint256[] memory loanIds = _acceptBatchLoanOffers(loanOfferIds, address(mockERC721Two));

    //     // Get loan details
    //     HySwapLending.Loan memory loanOne = hySwapLending.getLoanDetails(loanIds[0]);
    //     HySwapLending.Loan memory loanTwo = hySwapLending.getLoanDetails(loanIds[1]);
    //     HySwapLending.Loan memory loanThree = hySwapLending.getLoanDetails(loanIds[2]);

    //     // Assertions
    //     assertEq(loanOne.borrower, Bob);
    //     assertEq(loanOne.lender, Alice);
    //     assertEq(loanOne.nftCollection, address(mockERC721Two));
    //     assertEq(loanOne.tokenId, 1);
    //     assertEq(loanOne.principal, principalAmounts[0]);
    //     assertEq(loanOne.interest, interestAmounts[0]);
    //     assertEq(loanOne.fee, _getFee(interestAmounts[0]));
    //     assertEq(loanOne.collateralClaimed, false);
    //     assertEq(loanTwo.borrower, Bob);
    //     assertEq(loanTwo.lender, Alice);
    //     assertEq(loanTwo.nftCollection, address(mockERC721Two));
    //     assertEq(loanTwo.tokenId, 2);
    //     assertEq(loanTwo.principal, principalAmounts[1]);
    //     assertEq(loanTwo.interest, interestAmounts[1]);
    //     assertEq(loanTwo.fee, _getFee(interestAmounts[1]));
    //     assertEq(loanTwo.collateralClaimed, false);
    //     assertEq(loanThree.borrower, Bob);
    //     assertEq(loanThree.lender, Alice);
    //     assertEq(loanThree.nftCollection, address(mockERC721Two));
    //     assertEq(loanThree.tokenId, 3);
    //     assertEq(loanThree.principal, principalAmounts[2]);
    //     assertEq(loanThree.interest, interestAmounts[2]);
    //     assertEq(loanThree.fee, _getFee(interestAmounts[2]));
    //     assertEq(loanThree.collateralClaimed, false);
    // }

    // function test_batchAcceptLoanOffers_nftTransfers() public {
    //     uint256 numOffers = 3;

    //     // Setup loan offers
    //     (uint256[] memory loanOfferIds,,,,) = _setupBatchLoanOffers(numOffers, address(mockERC721Two));

    //     // Accept loans
    //     _acceptBatchLoanOffers(loanOfferIds, address(mockERC721Two));

    //     // Assertions
    //     assertEq(mockERC721Two.balanceOf(address(hySwapLending)), 3);
    //     assertEq(mockERC721Two.balanceOf(Bob), 0);
    // }

    // function test_batchCancelLoanOffers() public {
    //     uint256 numOffers = 3;

    //     // Get Alice pre-loan balance
    //     uint256 preAliceBalance = Alice.balance;

    //     // Setup loan offers
    //     (uint256[] memory loanOfferIds,,,,) = _setupBatchLoanOffers(numOffers, address(mockERC721Two));

    //     // Cancel loan offers
    //     vm.prank(Alice);
    //     hySwapLending.batchCancelLoanOffers(loanOfferIds);

    //     // Get loan offers
    //     HySwapLending.LoanOffer memory loanOfferOne = hySwapLending.getLoanOffer(loanOfferIds[0]);
    //     HySwapLending.LoanOffer memory loanOfferTwo = hySwapLending.getLoanOffer(loanOfferIds[1]);
    //     HySwapLending.LoanOffer memory loanOfferThree = hySwapLending.getLoanOffer(loanOfferIds[2]);

    //     // Assertions
    //     assertEq(hySwapLending.getLoanOfferCount(), 3);
    //     assertEq(hySwapLending.getLoanCount(), 0);
    //     assertEq(Alice.balance, preAliceBalance);
    //     assertEq(loanOfferOne.active, false);
    //     assertEq(loanOfferTwo.active, false);
    //     assertEq(loanOfferThree.active, false);
    // }

    // function test_batchRepayLoans_loanStates() public {
    //     uint256 numOffers = 3;

    //     // Setup loan offers
    //     (uint256[] memory loanOfferIds, uint96[] memory principalAmounts,,, uint256[] memory interestAmounts) =
    //         _setupBatchLoanOffers(numOffers, address(mockERC721Two));

    //     // Accept loans
    //     uint256[] memory loanIds = _acceptBatchLoanOffers(loanOfferIds, address(mockERC721Two));

    //     // Get total repayment amount
    //     uint256 totalRepayment;
    //     for (uint256 i = 0; i < numOffers; i++) {
    //         totalRepayment += principalAmounts[i] + interestAmounts[i] + _getFee(interestAmounts[i]);
    //     }

    //     // Repay loans
    //     vm.prank(Bob);
    //     hySwapLending.batchRepayLoans{value: totalRepayment}(loanIds);

    //     // Get loan details
    //     HySwapLending.Loan memory loanOne = hySwapLending.getLoanDetails(loanIds[0]);
    //     HySwapLending.Loan memory loanTwo = hySwapLending.getLoanDetails(loanIds[1]);
    //     HySwapLending.Loan memory loanThree = hySwapLending.getLoanDetails(loanIds[2]);

    //     // Assertions
    //     assertEq(loanOne.repaid, true);
    //     assertEq(loanTwo.repaid, true);
    //     assertEq(loanThree.repaid, true);
    //     assertEq(loanOne.collateralClaimed, false);
    //     assertEq(loanTwo.collateralClaimed, false);
    //     assertEq(loanThree.collateralClaimed, false);
    // }

    // function test_batchRepayLoans_nftTransfers() public {
    //     uint256 numOffers = 3;

    //     // Setup loan offers
    //     (uint256[] memory loanOfferIds, uint96[] memory principalAmounts,,, uint256[] memory interestAmounts) =
    //         _setupBatchLoanOffers(numOffers, address(mockERC721Two));

    //     // Accept loans
    //     uint256[] memory loanIds = _acceptBatchLoanOffers(loanOfferIds, address(mockERC721Two));

    //     // Get total repayment amount
    //     uint256 totalRepayment;
    //     for (uint256 i = 0; i < numOffers; i++) {
    //         totalRepayment += principalAmounts[i] + interestAmounts[i] + _getFee(interestAmounts[i]);
    //     }

    //     // Repay loans
    //     vm.prank(Bob);
    //     hySwapLending.batchRepayLoans{value: totalRepayment}(loanIds);

    //     // Assertions
    //     assertEq(mockERC721Two.balanceOf(address(hySwapLending)), 0);
    //     assertEq(mockERC721Two.balanceOf(Bob), 3);
    // }
}
