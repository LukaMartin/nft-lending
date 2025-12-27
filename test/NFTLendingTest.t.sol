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
        uint256 offerId,
        address indexed lender,
        address indexed nftCollection,
        uint256 interestRate,
        uint64 loanDuration,
        uint64 offerExpiry
    );
    event LoanAccepted(uint256 loanId, uint256 offerId, address indexed borrower, uint256 tokenId);
    event LoanRepaid(uint256 loanId, address indexed borrower);
    event CollateralClaimed(uint256 loanId, address indexed lender);
    event LoanOfferCanceled(uint256 offerId, address indexed lender);

    function setUp() public virtual override {
        BaseTest.setUp();
        _setUserNFTBalances();
        _whitelistCollections();
    }

    /*////////////////////////////////////////////////////////////////
                             HELPER FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function _setUserNFTBalances() internal {
        // Set user NFT balances
        mockERC721One.setTokenId(ALICE, 1);
        mockERC721One.setTokenId(ALICE, 2);
        mockERC721One.setTokenId(ALICE, 3);
        mockERC721One.setTokenId(ALICE, 4);
        mockERC721One.setTokenId(ALICE, 5);
        mockERC721One.setTokenId(ALICE, 6);
        mockERC721One.setTokenId(ALICE, 7);
        mockERC721One.setTokenId(ALICE, 8);
        mockERC721Two.setTokenId(BOB, 1);
        mockERC721Two.setTokenId(BOB, 2);
        mockERC721Two.setTokenId(BOB, 3);
        mockERC721Two.setTokenId(BOB, 4);
        mockERC721Two.setTokenId(BOB, 5);
        mockERC721Two.setTokenId(BOB, 6);
        mockERC721Two.setTokenId(BOB, 7);
        mockERC721Two.setTokenId(BOB, 8);

        // Assertions
        assertEq(mockERC721One.balanceOf(ALICE), 8);
        assertEq(mockERC721Two.balanceOf(BOB), 8);

        // Set approvals
        vm.prank(ALICE);
        mockERC721One.setApprovalForAll(address(nftLending), true);

        vm.prank(BOB);
        mockERC721Two.setApprovalForAll(address(nftLending), true);
    }

    function _whitelistCollections() internal {
        // Whitelist default mock collections
        vm.startPrank(deployer);
        nftLending.setCollectionWhitelisted(address(mockERC721One), true);
        nftLending.setCollectionWhitelisted(address(mockERC721Two), true);
        vm.stopPrank();
    }

    function _createLoanOffer(
        address nftCollection,
        uint96 principal,
        uint32 interestRateBps,
        uint64 loanDuration,
        uint64 offerExpiry
    ) internal returns (uint256) {
        vm.startPrank(ALICE);
        // Deposit wrapped native, and approve NFTLending to spend
        mockWrappedNative.deposit{value: principal}();
        mockWrappedNative.approve(address(nftLending), principal);

        // Create loan offer
        uint256 loanOfferId =
            nftLending.createLoanOffer(address(nftCollection), principal, interestRateBps, loanDuration, offerExpiry);
        vm.stopPrank();

        return loanOfferId;
    }

    function _repayLoan(uint256 loanId, address borrower, uint256 duration) internal returns (uint256, uint256) {
        // Get loan details
        NFTLending.Loan memory loan = nftLending.getLoanDetails(loanId);
        uint256 principal = loan.principal;
        uint256 interest = _calculateInterest(principal, loan.interestRateBps, duration);
        uint256 totalRepayment = principal + interest;
        uint256 preBorrowerBalance = mockWrappedNative.balanceOf(borrower);

        vm.startPrank(borrower);
        // Deposit wrapped native
        mockWrappedNative.deposit{value: totalRepayment - preBorrowerBalance}();
        mockWrappedNative.approve(address(nftLending), totalRepayment);

        // Repay loan
        nftLending.repayLoan(loanId);
        vm.stopPrank();

        return (totalRepayment, interest);
    }

    function _batchCreateLoanOffers(uint256 numOffers, address nftCollection)
        internal
        returns (uint256[] memory, uint96[] memory, uint32[] memory, uint64[] memory, uint64[] memory)
    {
        uint96[] memory principalAmounts = new uint96[](numOffers);
        uint32[] memory interestRatesBps = new uint32[](numOffers);
        uint64[] memory loanDurations = new uint64[](numOffers);
        uint64[] memory offerExpiries = new uint64[](numOffers);
        uint256 totalPrincipalAmount = 0;

        for (uint256 i = 0; i < numOffers; i++) {
            uint96 principalAmount = uint96(bound(vm.randomUint(), 0.01 ether, 10 ether));
            principalAmounts[i] = principalAmount;
            totalPrincipalAmount += principalAmount;
            interestRatesBps[i] = uint32(bound(vm.randomUint(), minInterestRateBps, maxInterestRateBps));
            loanDurations[i] = uint64(bound(vm.randomUint(), minLoanDuration, maxLoanDuration));
            offerExpiries[i] = uint64(block.timestamp + DEFAULT_OFFER_EXPIRY);
        }

        vm.startPrank(ALICE);
        // Deposit wrapped native, and approve NFTLending to spend
        mockWrappedNative.deposit{value: totalPrincipalAmount}();
        mockWrappedNative.approve(address(nftLending), totalPrincipalAmount);
        // Create loan offers
        uint256[] memory loanOfferIds = nftLending.batchCreateLoanOffers(
            nftCollection, principalAmounts, interestRatesBps, loanDurations, offerExpiries
        );
        vm.stopPrank();

        return (loanOfferIds, principalAmounts, interestRatesBps, loanDurations, offerExpiries);
    }

    function _acceptBatchLoanOffers(uint256[] memory loanOfferIds) internal returns (uint256[] memory) {
        uint256[] memory tokenIds = new uint256[](loanOfferIds.length);
        for (uint256 i = 0; i < loanOfferIds.length; i++) {
            tokenIds[i] = i + 1;
        }

        vm.prank(BOB);
        uint256[] memory loanIds = nftLending.batchAcceptLoanOffers(loanOfferIds, tokenIds);

        return loanIds;
    }

    function _calculateInterest(uint256 principal, uint256 interestRateBps, uint256 duration)
        internal
        pure
        returns (uint256)
    {
        return (principal * interestRateBps * duration) / (10000 * 365 days);
    }

    function _calculateLoanFee(uint256 principal) internal view returns (uint256) {
        return (principal * nftLending.getLoanFeeBps()) / 10000;
    }

    /*////////////////////////////////////////////////////////////////
                         CREATE LOAN OFFER TESTS
    ////////////////////////////////////////////////////////////////*/

    function testCreateLoanOfferRevertsWhenDurationIsLessThanMinDuration() public {
        // Initialize variables
        uint64 duration = 0.5 days; // Min duration is 1 day, attempt to create offer with 0.5 days
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;

        // Create loan offer with duration less than min duration
        vm.startPrank(ALICE);
        mockWrappedNative.deposit{value: DEFAULT_PRINCIPAL}();
        mockWrappedNative.approve(address(nftLending), DEFAULT_PRINCIPAL);
        vm.expectRevert(NFTLending.InvalidDuration.selector);
        nftLending.createLoanOffer(
            address(mockERC721One), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, duration, offerExpiry
        );
        vm.stopPrank();
    }

    function testCreateLoanOfferRevertsWhenInterestRateIsLessThanMinInterestRate() public {
        // Initialize variables
        uint32 interestRateBps = 99; // Min interest rate is 100 bps, attempt to create offer with 99 bps
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;

        // Create loan offer with interest rate less than min interest rate
        vm.startPrank(ALICE);
        mockWrappedNative.deposit{value: DEFAULT_PRINCIPAL}();
        mockWrappedNative.approve(address(nftLending), DEFAULT_PRINCIPAL);
        vm.expectRevert(NFTLending.InvalidInterestRate.selector);
        nftLending.createLoanOffer(
            address(mockERC721One), DEFAULT_PRINCIPAL, interestRateBps, DEFAULT_DURATION, offerExpiry
        );
        vm.stopPrank();
    }

    function testCreateLoanOfferRevertsWhenInterestRateIsGreaterThanMaxInterestRate() public {
        // Initialize variables
        uint32 interestRateBps = 30001; // Max interest rate is 30000 bps, attempt to create offer with 30001 bps
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;

        // Create loan offer with interest rate greater than max interest rate
        vm.startPrank(ALICE);
        mockWrappedNative.deposit{value: DEFAULT_PRINCIPAL}();
        mockWrappedNative.approve(address(nftLending), DEFAULT_PRINCIPAL);
        vm.expectRevert(NFTLending.InvalidInterestRate.selector);
        nftLending.createLoanOffer(
            address(mockERC721One), DEFAULT_PRINCIPAL, interestRateBps, DEFAULT_DURATION, offerExpiry
        );
        vm.stopPrank();
    }

    function testCreateLoanOfferRevertsWhenDurationIsGreaterThanMaxDuration() public {
        // Initialize variables
        uint64 duration = 30 days + 1 seconds; // Max duration is 30 days
        uint64 offerExpiry = uint64(block.timestamp) + duration;

        // Create loan offer with duration greater than max duration
        vm.startPrank(ALICE);
        mockWrappedNative.deposit{value: DEFAULT_PRINCIPAL}();
        mockWrappedNative.approve(address(nftLending), DEFAULT_PRINCIPAL);
        vm.expectRevert(NFTLending.InvalidDuration.selector);
        nftLending.createLoanOffer(
            address(mockERC721One), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, duration, offerExpiry
        );
        vm.stopPrank();
    }

    function testCreateLoanOfferRevertsWhenOfferExpiryIsInThePast() public {
        // Initialize variables
        uint64 offerExpiry = uint64(block.timestamp) - 1 seconds;

        // Create loan offer with offer expiry in the past
        vm.startPrank(ALICE);
        mockWrappedNative.deposit{value: DEFAULT_PRINCIPAL}();
        mockWrappedNative.approve(address(nftLending), DEFAULT_PRINCIPAL);
        vm.expectRevert(abi.encodeWithSelector(NFTLending.InvalidOfferExpiry.selector, offerExpiry, block.timestamp));
        nftLending.createLoanOffer(
            address(mockERC721One), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );
        vm.stopPrank();
    }

    function testCreateLoanOfferRevertsWhenCollectionIsNotWhitelisted() public {
        // Initialize variables
        address nftCollection = address(0);
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;

        // Create loan offer with collection not whitelisted
        vm.startPrank(ALICE);
        mockWrappedNative.deposit{value: DEFAULT_PRINCIPAL}();
        mockWrappedNative.approve(address(nftLending), DEFAULT_PRINCIPAL);
        vm.expectRevert(abi.encodeWithSelector(NFTLending.CollectionNotWhitelisted.selector, nftCollection));
        nftLending.createLoanOffer(
            nftCollection, DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );
        vm.stopPrank();
    }

    function testCreateLoanOfferRevertsWhenLenderInsufficientWrappedNativeBalance() public {
        // Initialize variables
        uint96 principal = 10 ether;
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;

        // Create loan offer with lender insufficient wrapped native balance
        vm.startPrank(ALICE);
        mockWrappedNative.deposit{value: principal - 1 wei}(); // Deposit less than principal
        mockWrappedNative.approve(address(nftLending), principal);
        vm.expectRevert(
            abi.encodeWithSelector(
                NFTLending.LenderInsufficientWrappedNativeBalance.selector,
                mockWrappedNative.balanceOf(ALICE),
                principal
            )
        );
        nftLending.createLoanOffer(
            address(mockERC721One), principal, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );
        vm.stopPrank();
    }

    function testCreateLoanOfferRevertsWhenLenderInsufficientWrappedNativeAllowance() public {
        // Initialize variables
        uint96 principal = 10 ether;
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;

        // Create loan offer with lender insufficient wrapped native allowance
        vm.startPrank(ALICE);
        mockWrappedNative.deposit{value: principal}();
        mockWrappedNative.approve(address(nftLending), principal - 1 wei); // Approve less than principal
        vm.expectRevert(
            abi.encodeWithSelector(
                NFTLending.LenderInsufficientWrappedNativeAllowance.selector,
                mockWrappedNative.allowance(ALICE, address(nftLending)),
                principal
            )
        );
        nftLending.createLoanOffer(
            address(mockERC721One), principal, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );
        vm.stopPrank();
    }

    function testCreateLoanOfferIncrementsNextOfferId() public {
        // Initialize variables
        uint256 nextOfferId = nftLending.getLoanOfferCount();
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;

        // Create loan offer
        _createLoanOffer(
            address(mockERC721One), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );

        // Assertions
        assertEq(nftLending.getLoanOfferCount(), nextOfferId + 1);
    }

    function testCreateLoanOfferAndAssertLoanOfferDetails() public {
        // Get current loan offer count
        uint256 loanOfferCount = nftLending.getLoanOfferCount();
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;

        // Create loan offer
        uint256 loanOfferId = _createLoanOffer(
            address(mockERC721One), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );

        // Get loan offer
        NFTLending.LoanOffer memory loanOffer = nftLending.getLoanOffer(loanOfferId);

        // Assertions
        assertEq(loanOfferCount, loanOfferId);
        assertEq(loanOffer.lender, ALICE);
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
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;

        // Create loan offer
        vm.startPrank(ALICE);
        mockWrappedNative.deposit{value: DEFAULT_PRINCIPAL}();
        mockWrappedNative.approve(address(nftLending), DEFAULT_PRINCIPAL);

        // Expect loan offer created event
        vm.expectEmit(true, true, true, true);
        emit LoanOfferCreated(
            loanOfferId, ALICE, address(mockERC721One), DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );
        nftLending.createLoanOffer(
            address(mockERC721One), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );
        vm.stopPrank();
    }

    function testBatchCreateLoanOffersRevertsWhenBatchSizeIsZero() public {
        // Initialize variables
        uint96[] memory principalAmounts = new uint96[](0);
        uint32[] memory interestRatesBps = new uint32[](0);
        uint64[] memory loanDurations = new uint64[](0);
        uint64[] memory offerExpiries = new uint64[](0);

        vm.prank(ALICE);
        // Create loan offers with batch size 0
        vm.expectRevert(NFTLending.BatchLengthCannotBeZero.selector);
        nftLending.batchCreateLoanOffers(
            address(mockERC721One), principalAmounts, interestRatesBps, loanDurations, offerExpiries
        );
    }

    function testBatchCreateLoanOffersRevertsWhenBatchSizeExceedsLimit() public {
        // Initialize variables
        uint256 batchLimit = nftLending.getBatchLimit();
        uint256 batchSize = batchLimit + 1; // Batch size exceeds limit
        uint96[] memory principalAmounts = new uint96[](batchSize);
        uint32[] memory interestRatesBps = new uint32[](batchSize);
        uint64[] memory loanDurations = new uint64[](batchSize);
        uint64[] memory offerExpiries = new uint64[](batchSize);

        vm.prank(ALICE);
        // Create loan offers
        vm.expectRevert(abi.encodeWithSelector(NFTLending.BatchLimitExceeded.selector, batchSize, batchLimit));
        nftLending.batchCreateLoanOffers(
            address(mockERC721One), principalAmounts, interestRatesBps, loanDurations, offerExpiries
        );
    }

    function testBatchCreateLoanOffersRevertsWhenInputParameterLengthMismatch() public {
        // Initialize variables
        uint96[] memory principalAmounts = new uint96[](1);
        uint32[] memory interestRatesBps = new uint32[](2); // Interest length is longer than principal amounts, loan durations, and offer expiries
        uint64[] memory loanDurations = new uint64[](1);
        uint64[] memory offerExpiries = new uint64[](1);

        vm.prank(ALICE);
        // Create loan offers
        vm.expectRevert(NFTLending.InputParameterLengthMismatch.selector);
        nftLending.batchCreateLoanOffers(
            address(mockERC721One), principalAmounts, interestRatesBps, loanDurations, offerExpiries
        );
    }

    function testBatchCreateLoanOffersRevertsWhenLenderInsufficientWrappedNativeBalance() public {
        // Initialize variables
        uint256 numOffers = 3;
        uint96[] memory principalAmounts = new uint96[](numOffers);
        uint32[] memory interestRatesBps = new uint32[](numOffers);
        uint64[] memory loanDurations = new uint64[](numOffers);
        uint64[] memory offerExpiries = new uint64[](numOffers);
        uint256 totalPrincipalAmount = 0;

        for (uint256 i = 0; i < numOffers; i++) {
            uint96 principalAmount = uint96(bound(vm.randomUint(), 0.01 ether, 10 ether));
            principalAmounts[i] = principalAmount;
            totalPrincipalAmount += principalAmount;
            interestRatesBps[i] = uint32(bound(vm.randomUint(), minInterestRateBps, maxInterestRateBps));
            loanDurations[i] = uint64(bound(vm.randomUint(), minLoanDuration, maxLoanDuration));
            offerExpiries[i] = uint64(block.timestamp + DEFAULT_OFFER_EXPIRY);
        }

        vm.startPrank(ALICE);
        // Deposit insufficient wrapped native balance
        mockWrappedNative.deposit{value: totalPrincipalAmount - 1 wei}(); // Deposit less than total principal amount
        mockWrappedNative.approve(address(nftLending), totalPrincipalAmount);
        // Create loan offers
        vm.expectRevert(
            abi.encodeWithSelector(
                NFTLending.LenderInsufficientWrappedNativeBalance.selector,
                mockWrappedNative.balanceOf(ALICE),
                totalPrincipalAmount
            )
        );
        nftLending.batchCreateLoanOffers(
            address(mockERC721One), principalAmounts, interestRatesBps, loanDurations, offerExpiries
        );
        vm.stopPrank();
    }

    function testBatchCreateLoanOffersRevertsWhenLenderInsufficientWrappedNativeAllowance() public {
        // Initialize variables
        uint256 numOffers = 3;
        uint96[] memory principalAmounts = new uint96[](numOffers);
        uint32[] memory interestRatesBps = new uint32[](numOffers);
        uint64[] memory loanDurations = new uint64[](numOffers);
        uint64[] memory offerExpiries = new uint64[](numOffers);
        uint256 totalPrincipalAmount = 0;

        for (uint256 i = 0; i < numOffers; i++) {
            uint96 principalAmount = uint96(bound(vm.randomUint(), 0.01 ether, 10 ether));
            principalAmounts[i] = principalAmount;
            totalPrincipalAmount += principalAmount;
            interestRatesBps[i] = uint32(bound(vm.randomUint(), minInterestRateBps, maxInterestRateBps));
            loanDurations[i] = uint64(bound(vm.randomUint(), minLoanDuration, maxLoanDuration));
            offerExpiries[i] = uint64(block.timestamp + DEFAULT_OFFER_EXPIRY);
        }

        vm.startPrank(ALICE);
        // Approve insufficient wrapped native allowance
        mockWrappedNative.deposit{value: totalPrincipalAmount}();
        mockWrappedNative.approve(address(nftLending), totalPrincipalAmount - 1 wei); // Approve less than total principal amount
        // Create loan offers
        vm.expectRevert(
            abi.encodeWithSelector(
                NFTLending.LenderInsufficientWrappedNativeAllowance.selector,
                mockWrappedNative.allowance(ALICE, address(nftLending)),
                totalPrincipalAmount
            )
        );
        nftLending.batchCreateLoanOffers(
            address(mockERC721One), principalAmounts, interestRatesBps, loanDurations, offerExpiries
        );
        vm.stopPrank();
    }

    function testBatchCreateLoanOffersCorrectlyCreatesLoanOffers() public {
        uint256 numOffers = 8;
        uint256 preOfferCount = nftLending.getLoanOfferCount();

        (
            uint256[] memory loanOfferIds,
            uint96[] memory principalAmounts,
            uint32[] memory interestRatesBps,
            uint64[] memory loanDurations,
            uint64[] memory offerExpiries
        ) = _batchCreateLoanOffers(numOffers, address(mockERC721One));

        // Verify correct number of offers returned
        assertEq(loanOfferIds.length, numOffers);

        // Verify offer count incremented correctly
        assertEq(nftLending.getLoanOfferCount(), preOfferCount + numOffers);

        // Verify each offer's details
        for (uint256 i = 0; i < numOffers; i++) {
            // Verify sequential IDs
            assertEq(loanOfferIds[i], preOfferCount + i);

            NFTLending.LoanOffer memory offer = nftLending.getLoanOffer(loanOfferIds[i]);
            assertEq(offer.lender, ALICE);
            assertEq(offer.nftCollection, address(mockERC721One));
            assertEq(offer.principal, principalAmounts[i]);
            assertEq(offer.interestRateBps, interestRatesBps[i]);
            assertEq(offer.loanDuration, loanDurations[i]);
            assertEq(offer.offerExpiry, offerExpiries[i]);
            assertEq(offer.active, true);
        }
    }

    /*////////////////////////////////////////////////////////////////
                         ACCEPT LOAN OFFER TESTS
    ////////////////////////////////////////////////////////////////*/

    function testAcceptLoanOfferRevertsWhenOfferIsInactive() public {
        // Initialize variables
        uint256 tokenId = 1;
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;

        // Create loan offer
        uint256 loanOfferId = _createLoanOffer(
            address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );

        // Accept loan offer
        vm.prank(BOB);
        nftLending.acceptLoanOffer(loanOfferId, tokenId);

        // Try to accept loan offer again
        vm.prank(BOB);
        vm.expectRevert(NFTLending.OfferInactive.selector);
        nftLending.acceptLoanOffer(loanOfferId, tokenId);
    }

    function testAcceptLoanOfferRevertsWhenOfferIsExpired() public {
        // Initialize variables
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;
        uint256 tokenId = 1;

        // Create loan offer
        uint256 loanOfferId = _createLoanOffer(
            address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );

        // Warp to offer expiry + 1 second
        vm.warp(offerExpiry + 1 seconds);

        // Try to accept loan offer
        vm.prank(BOB);
        vm.expectRevert(NFTLending.OfferExpired.selector);
        nftLending.acceptLoanOffer(loanOfferId, tokenId);
    }

    function testAcceptLoanOfferRevertsWhenNotNFTOwner() public {
        // Initialize variables
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;
        uint256 tokenId = 1;

        // Create loan offer
        uint256 loanOfferId = _createLoanOffer(
            address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );

        // Try to accept loan offer
        vm.prank(CHARLIE); // Charlie is not the owner of the NFT
        vm.expectRevert(abi.encodeWithSelector(NFTLending.NotNFTOwner.selector, BOB, CHARLIE));
        nftLending.acceptLoanOffer(loanOfferId, tokenId);
    }

    function testAcceptLoanOfferCorrectlyCreatesLoan() public {
        // Initialize variables
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;
        uint256 tokenId = 1;

        // Create loan offer
        uint256 loanOfferId = _createLoanOffer(
            address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );

        // Accept loan offer
        vm.prank(BOB);
        uint256 loanId = nftLending.acceptLoanOffer(loanOfferId, tokenId);

        // Get loan offer & loan
        NFTLending.LoanOffer memory loanOffer = nftLending.getLoanOffer(loanOfferId);
        NFTLending.Loan memory loan = nftLending.getLoanDetails(loanId);

        // Assertions
        assertEq(loan.borrower, BOB);
        assertEq(loan.lender, ALICE);
        assertEq(loan.nftCollection, address(mockERC721Two));
        assertEq(loan.tokenId, tokenId);
        assertEq(loan.principal, DEFAULT_PRINCIPAL);
        assertEq(loan.interestRateBps, DEFAULT_INTEREST_RATE_BPS);
        assertEq(loan.loanDuration, DEFAULT_DURATION);
        assertEq(loan.fee, _calculateLoanFee(DEFAULT_PRINCIPAL));
        assertEq(loan.repaid, false);
        assertEq(loan.collateralClaimed, false);
        assertEq(loanOffer.active, false);
    }

    function testAcceptLoanOfferIncrementsNextLoanId() public {
        // Initialize variables
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;
        uint256 tokenId = 1;

        // Create loan offer
        uint256 loanOfferId = _createLoanOffer(
            address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );

        // Accept loan offer
        vm.prank(BOB);
        uint256 loanId = nftLending.acceptLoanOffer(loanOfferId, tokenId);

        // Assertions
        assertEq(nftLending.getLoanCount(), loanId + 1);
    }

    function testAcceptLoanOfferEmitsLoanAcceptedEvent() public {
        // Initialize variables
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;
        uint256 tokenId = 1;

        // Create loan offer
        uint256 loanOfferId = _createLoanOffer(
            address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );

        // Get loan ID
        uint256 loanId = nftLending.getLoanCount();

        // Expect loan accepted event
        vm.expectEmit(true, true, true, true);
        emit LoanAccepted(loanId, loanOfferId, BOB, tokenId);

        // Accept loan offer
        vm.prank(BOB);
        nftLending.acceptLoanOffer(loanOfferId, tokenId);
    }

    function testAcceptLoanOfferCorrectlyTransfersNFTAndWrappedNativeTokens() public {
        // Initialize variables
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;
        uint256 tokenId = 1;
        uint256 loanFee = _calculateLoanFee(DEFAULT_PRINCIPAL);
        uint256 loanAmountAfterFee = DEFAULT_PRINCIPAL - loanFee;

        // Create loan offer
        uint256 loanOfferId = _createLoanOffer(
            address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );
        uint256 preBobBalance = mockWrappedNative.balanceOf(BOB);
        uint256 preAliceBalance = mockWrappedNative.balanceOf(ALICE);

        // Accept loan offer
        vm.prank(BOB);
        nftLending.acceptLoanOffer(loanOfferId, tokenId);

        // Assertions
        assertEq(mockERC721Two.balanceOf(address(nftLending)), 1);
        assertEq(mockERC721Two.balanceOf(BOB), 7);
        assertEq(mockERC721Two.ownerOf(tokenId), address(nftLending));
        assertEq(mockWrappedNative.balanceOf(BOB), preBobBalance + loanAmountAfterFee);
        assertEq(mockWrappedNative.balanceOf(ALICE), preAliceBalance - DEFAULT_PRINCIPAL);
        assertEq(mockWrappedNative.balanceOf(treasury), loanFee);
    }

    function testBatchAcceptLoanOffersRevertsWhenBatchSizeIsZero() public {
        // Initialize variables
        uint256[] memory offerIds = new uint256[](0);
        uint256[] memory tokenIds = new uint256[](0);

        vm.prank(BOB);
        vm.expectRevert(NFTLending.BatchLengthCannotBeZero.selector);
        nftLending.batchAcceptLoanOffers(offerIds, tokenIds);
    }

    function testBatchAcceptLoanOffersRevertsWhenBatchSizeExceedsLimit() public {
        // Initialize variables
        uint256 batchLimit = nftLending.getBatchLimit();
        uint256 batchSize = batchLimit + 1; // Batch size exceeds limit
        uint256[] memory offerIds = new uint256[](batchSize);
        uint256[] memory tokenIds = new uint256[](batchSize);

        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(NFTLending.BatchLimitExceeded.selector, batchSize, batchLimit));
        nftLending.batchAcceptLoanOffers(offerIds, tokenIds);
    }

    function testBatchAcceptLoanOffersRevertsWhenOfferIdsLengthMismatch() public {
        // Initialize variables
        uint256 numOffers = 2;

        // Create loan offers
        (uint256[] memory loanOfferIds,,,,) = _batchCreateLoanOffers(numOffers, address(mockERC721One));

        uint256[] memory offerIds = loanOfferIds;
        uint256[] memory tokenIds = new uint256[](numOffers + 1); // Token IDs length is longer than offer IDs
        tokenIds[0] = 1;
        tokenIds[1] = 2;
        tokenIds[2] = 3;

        vm.prank(BOB);
        // Accept loan offers
        vm.expectRevert(NFTLending.InputParameterLengthMismatch.selector);
        nftLending.batchAcceptLoanOffers(offerIds, tokenIds);
    }

    function testBatchAcceptLoanOffersCorrectlyAcceptsLoanOffers() public {
        // Initialize variables
        uint256 numOffers = 2;
        uint256 preLoanCount = nftLending.getLoanCount();

        // Create loan offers
        (
            uint256[] memory loanOfferIds,
            uint96[] memory principalAmounts,
            uint32[] memory interestRatesBps,
            uint64[] memory loanDurations,
        ) = _batchCreateLoanOffers(numOffers, address(mockERC721Two));
        uint256[] memory tokenIds = new uint256[](numOffers);
        for (uint256 i = 0; i < numOffers; i++) {
            tokenIds[i] = i + 1;
        }

        vm.prank(BOB);
        uint256[] memory loanIds = nftLending.batchAcceptLoanOffers(loanOfferIds, tokenIds);

        // Assertions
        assertEq(loanIds.length, numOffers);

        for (uint256 i = 0; i < numOffers; i++) {
            assertEq(loanIds[i], preLoanCount + i);

            NFTLending.Loan memory loan = nftLending.getLoanDetails(loanIds[i]);
            assertEq(loan.borrower, BOB);
            assertEq(loan.lender, ALICE);
            assertEq(loan.nftCollection, address(mockERC721Two));
            assertEq(loan.tokenId, tokenIds[i]);
            assertEq(loan.principal, principalAmounts[i]);
            assertEq(loan.interestRateBps, interestRatesBps[i]);
            assertEq(loan.loanDuration, loanDurations[i]);
            assertEq(loan.fee, _calculateLoanFee(principalAmounts[i]));
            assertEq(loan.repaid, false);
            assertEq(loan.collateralClaimed, false);
            assertEq(loan.startTime, block.timestamp);
            assertEq(loan.loanDuration, loanDurations[i]);
            assertEq(loan.interestRateBps, interestRatesBps[i]);
            assertEq(loan.repaid, false);
            assertEq(loan.collateralClaimed, false);
        }
    }
    /*////////////////////////////////////////////////////////////////
                         CANCEL LOAN OFFER TESTS
    ////////////////////////////////////////////////////////////////*/

    function testCancelLoanOfferRevertsWhenOfferIsAlreadyAccepted() public {
        // Initialize variables
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;
        uint256 tokenId = 1;

        // Create loan offer
        uint256 loanOfferId = _createLoanOffer(
            address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );

        // Accept loan offer
        vm.prank(BOB);
        nftLending.acceptLoanOffer(loanOfferId, tokenId);

        // Try to cancel loan offer
        vm.prank(ALICE);
        vm.expectRevert(NFTLending.OfferInactive.selector);
        nftLending.cancelLoanOffer(loanOfferId);
    }

    function testCancelLoanOfferRevertsWhenOfferIsAlreadyCancelled() public {
        // Initialize variables
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;

        // Create loan offer
        uint256 loanOfferId = _createLoanOffer(
            address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );

        // Cancel loan offer
        vm.prank(ALICE);
        nftLending.cancelLoanOffer(loanOfferId);

        // Try to cancel loan offer again
        vm.prank(ALICE);
        vm.expectRevert(NFTLending.OfferInactive.selector);
        nftLending.cancelLoanOffer(loanOfferId);
    }

    function testCancelLoanOfferRevertsWhenNotLender() public {
        // Initialize variables
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;

        // Create loan offer
        uint256 loanOfferId = _createLoanOffer(
            address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );

        // Try to cancel loan offer
        vm.prank(CHARLIE); // Charlie is not the lender
        vm.expectRevert(abi.encodeWithSelector(NFTLending.NotLender.selector, ALICE, CHARLIE));
        nftLending.cancelLoanOffer(loanOfferId);
    }

    function testCancelLoanOfferCorrectlySetsOfferIsActiveToFalse() public {
        // Initialize variables
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;

        // Create loan offer
        uint256 loanOfferId = _createLoanOffer(
            address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );

        // Cancel loan offer
        vm.prank(ALICE);
        nftLending.cancelLoanOffer(loanOfferId);

        // Get loan offer
        NFTLending.LoanOffer memory loanOffer = nftLending.getLoanOffer(loanOfferId);

        // Assertions
        assertEq(loanOffer.active, false);
    }

    function testCancelLoanOfferEmitsLoanOfferCanceledEvent() public {
        // Initialize variables
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;

        // Create loan offer
        uint256 loanOfferId = _createLoanOffer(
            address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );

        // Expect loan offer canceled event
        vm.expectEmit(true, true, true, true);
        emit LoanOfferCanceled(loanOfferId, ALICE);

        // Cancel loan offer
        vm.prank(ALICE);
        nftLending.cancelLoanOffer(loanOfferId);
    }

    /*////////////////////////////////////////////////////////////////
                          REPAY LOAN OFFER TESTS
    ////////////////////////////////////////////////////////////////*/

    function testRepayLoanRevertsWhenLoanIsAlreadyRepaid() public {
        // Initialize variables
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;
        uint256 tokenId = 1;

        // Create loan offer
        uint256 loanOfferId = _createLoanOffer(
            address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );

        // Accept loan offer
        vm.startPrank(BOB);
        uint256 loanId = nftLending.acceptLoanOffer(loanOfferId, tokenId);

        // Warp loan duration
        vm.warp(block.timestamp + DEFAULT_DURATION);

        // Repay loan
        _repayLoan(loanId, BOB, DEFAULT_DURATION);

        // Try to repay loan again
        vm.expectRevert(NFTLending.LoanAlreadyRepaid.selector);
        nftLending.repayLoan(loanId);

        vm.stopPrank();
    }

    function testRepayLoanRevertsWhenNotBorrower() public {
        // Initialize variables
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;
        uint256 tokenId = 1;

        // Create loan offer
        uint256 loanOfferId = _createLoanOffer(
            address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );

        // Accept loan offer
        vm.prank(BOB);
        uint256 loanId = nftLending.acceptLoanOffer(loanOfferId, tokenId);

        // Try to repay loan
        vm.prank(CHARLIE); // Charlie is not the borrower
        vm.expectRevert(abi.encodeWithSelector(NFTLending.NotBorrower.selector, BOB, CHARLIE));
        nftLending.repayLoan(loanId);
    }

    function testRepayLoanRevertsWhenLoanIsExpired() public {
        // Initialize variables
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;
        uint256 tokenId = 1;

        // Create loan offer
        uint256 loanOfferId = _createLoanOffer(
            address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );

        // Accept loan offer
        vm.startPrank(BOB);
        uint256 loanId = nftLending.acceptLoanOffer(loanOfferId, tokenId);

        // Get loan details
        NFTLending.Loan memory loan = nftLending.getLoanDetails(loanId);
        uint256 loanEndTimestamp = loan.startTime + loan.loanDuration;
        uint256 warpTimestamp = loanEndTimestamp + 1 seconds;

        // Skip just over 30 days
        vm.warp(warpTimestamp);

        // Try to repay loan
        vm.expectRevert(abi.encodeWithSelector(NFTLending.LoanExpired.selector, block.timestamp, loanEndTimestamp));
        nftLending.repayLoan(loanId);

        vm.stopPrank();
    }

    function testRepayLoanUpdatesLoanState() public {
        // Initialize variables
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;
        uint256 tokenId = 1;

        // Create loan offer
        uint256 loanOfferId = _createLoanOffer(
            address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );

        // Accept loan offer
        vm.startPrank(BOB);
        uint256 loanId = nftLending.acceptLoanOffer(loanOfferId, tokenId);

        // Warp loan duration
        vm.warp(block.timestamp + DEFAULT_DURATION);

        // Repay loan
        _repayLoan(loanId, BOB, DEFAULT_DURATION);

        // Get loan details
        NFTLending.Loan memory loan = nftLending.getLoanDetails(loanId);

        // Assertions
        assertEq(loan.repaid, true);
    }

    function testRepayLoanEmitsLoanRepaidEvent() public {
        // Initialize variables
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;
        uint256 tokenId = 1;

        // Create loan offer
        uint256 loanOfferId = _createLoanOffer(
            address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );

        // Accept loan offer
        vm.startPrank(BOB);
        uint256 loanId = nftLending.acceptLoanOffer(loanOfferId, tokenId);

        // Get loan details
        NFTLending.Loan memory loan = nftLending.getLoanDetails(loanId);
        uint256 principal = loan.principal;
        uint256 interest = _calculateInterest(principal, loan.interestRateBps, loan.loanDuration);
        uint256 totalRepayment = principal + interest;

        // Deposit wrapped native
        mockWrappedNative.deposit{value: totalRepayment}();
        mockWrappedNative.approve(address(nftLending), totalRepayment);

        // Expect loan repaid event
        vm.expectEmit(true, true, true, true);
        emit LoanRepaid(loanId, BOB);

        // Repay loan
        nftLending.repayLoan(loanId);
        vm.stopPrank();
    }

    function testRepayLoanCorrectlyTransfersNFTAndWrappedNativeTokens() public {
        // Initialize variables
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;
        uint256 tokenId = 1;

        // Create loan offer
        uint256 loanOfferId = _createLoanOffer(
            address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );

        // Get pre-balances
        uint256 preAliceBalance = mockWrappedNative.balanceOf(ALICE);

        // Accept loan offer
        vm.startPrank(BOB);
        uint256 loanId = nftLending.acceptLoanOffer(loanOfferId, tokenId);

        // Warp loan duration
        vm.warp(block.timestamp + DEFAULT_DURATION);

        // Repay loan
        (, uint256 interest) = _repayLoan(loanId, BOB, DEFAULT_DURATION);

        // Assertions
        assertEq(mockERC721Two.balanceOf(address(nftLending)), 0);
        assertEq(mockERC721Two.balanceOf(BOB), 8);
        assertEq(mockERC721Two.ownerOf(tokenId), BOB);
        assertEq(mockWrappedNative.balanceOf(BOB), 0);
        assertEq(mockWrappedNative.balanceOf(ALICE), preAliceBalance + interest);
    }

    function testRepayLoanCorrectlyTransfersNFTAndWrappedNativeTokensForEarlyRepayment() public {
        // Initialize variables
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;
        uint256 tokenId = 1;

        // Create loan offer
        uint256 loanOfferId = _createLoanOffer(
            address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );

        // Get pre-balances
        uint256 preAliceBalance = mockWrappedNative.balanceOf(ALICE);

        // Accept loan offer
        vm.startPrank(BOB);
        uint256 loanId = nftLending.acceptLoanOffer(loanOfferId, tokenId);

        // Warp loan duration
        vm.warp(block.timestamp + 7 days);

        // Repay loan
        (, uint256 interest) = _repayLoan(loanId, BOB, 7 days);
        vm.stopPrank();

        // Assertions
        assertEq(mockERC721Two.balanceOf(address(nftLending)), 0);
        assertEq(mockERC721Two.balanceOf(BOB), 8);
        assertEq(mockERC721Two.ownerOf(tokenId), BOB);
        assertEq(mockWrappedNative.balanceOf(BOB), 0);
        assertEq(mockWrappedNative.balanceOf(ALICE), preAliceBalance + interest);
    }

    /*////////////////////////////////////////////////////////////////
                          CLAIM COLLATERAL TESTS
    ////////////////////////////////////////////////////////////////*/

    function testClaimCollateralRevertsWhenLoanIsAlreadyRepaid() public {
        // Initialize variables
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;
        uint256 tokenId = 1;

        // Create loan offer
        uint256 loanOfferId = _createLoanOffer(
            address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );

        // Accept loan offer
        vm.startPrank(BOB);
        uint256 loanId = nftLending.acceptLoanOffer(loanOfferId, tokenId);

        // Warp loan duration
        vm.warp(block.timestamp + DEFAULT_DURATION);

        // Repay loan
        _repayLoan(loanId, BOB, DEFAULT_DURATION);
        vm.stopPrank();

        // Try to claim collateral
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(NFTLending.LoanAlreadyRepaid.selector));
        nftLending.claimCollateral(loanId);
    }

    function testClaimCollateralRevertsWhenCollateralIsAlreadyClaimed() public {
        // Initialize variables
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;
        uint256 tokenId = 1;

        // Create loan offer
        uint256 loanOfferId = _createLoanOffer(
            address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );

        // Accept loan offer
        vm.prank(BOB);
        uint256 loanId = nftLending.acceptLoanOffer(loanOfferId, tokenId);

        // Warp loan duration
        vm.warp(block.timestamp + DEFAULT_DURATION + 1 seconds);

        // Try to claim collateral
        vm.startPrank(ALICE);
        nftLending.claimCollateral(loanId);

        // Try to claim collateral again
        vm.expectRevert(abi.encodeWithSelector(NFTLending.CollateralAlreadyClaimed.selector));
        nftLending.claimCollateral(loanId);
        vm.stopPrank();
    }

    function testClaimCollateralRevertsWhenLoanIsNotExpired() public {
        // Initialize variables
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;
        uint256 tokenId = 1;

        // Create loan offer
        uint256 loanOfferId = _createLoanOffer(
            address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );

        // Accept loan offer
        vm.prank(BOB);
        uint256 loanId = nftLending.acceptLoanOffer(loanOfferId, tokenId);

        // Get loan details
        NFTLending.Loan memory loan = nftLending.getLoanDetails(loanId);
        uint256 loanEndTimestamp = loan.startTime + loan.loanDuration;

        // Skip just over 30 days
        vm.warp(block.timestamp + DEFAULT_DURATION);

        // Try to claim collateral
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(NFTLending.LoanNotExpired.selector, block.timestamp, loanEndTimestamp));
        nftLending.claimCollateral(loanId);
    }

    function testClaimCollateralRevertsWhenNotLender() public {
        // Initialize variables
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;
        uint256 tokenId = 1;

        // Create loan offer
        uint256 loanOfferId = _createLoanOffer(
            address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );

        // Accept loan offer
        vm.prank(BOB);
        uint256 loanId = nftLending.acceptLoanOffer(loanOfferId, tokenId);

        // Warp just over loan duration
        vm.warp(block.timestamp + DEFAULT_DURATION + 1 seconds);

        // Try to claim collateral
        vm.prank(CHARLIE); // Charlie is not the lender
        vm.expectRevert(abi.encodeWithSelector(NFTLending.NotLender.selector, ALICE, CHARLIE));
        nftLending.claimCollateral(loanId);
    }

    function testClaimCollateralUpdatesLoanState() public {
        // Initialize variables
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;
        uint256 tokenId = 1;

        // Create loan offer
        uint256 loanOfferId = _createLoanOffer(
            address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );

        // Accept loan offer
        vm.prank(BOB);
        uint256 loanId = nftLending.acceptLoanOffer(loanOfferId, tokenId);

        // Warp past loan duration
        vm.warp(block.timestamp + DEFAULT_DURATION + 1 seconds);

        // Claim collateral
        vm.prank(ALICE);
        nftLending.claimCollateral(loanId);

        // Get loan details
        NFTLending.Loan memory loan = nftLending.getLoanDetails(loanId);

        // Assertions
        assertEq(loan.collateralClaimed, true);
    }

    function testClaimCollateralEmitsCollateralClaimedEvent() public {
        // Initialize variables
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;
        uint256 tokenId = 1;

        // Create loan offer
        uint256 loanOfferId = _createLoanOffer(
            address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );

        // Accept loan offer
        vm.prank(BOB);
        uint256 loanId = nftLending.acceptLoanOffer(loanOfferId, tokenId);

        // Warp past loan duration
        vm.warp(block.timestamp + DEFAULT_DURATION + 1 seconds);

        // Expect collateral claimed event
        vm.expectEmit(true, true, true, true);
        emit CollateralClaimed(loanId, ALICE);

        // Claim collateral
        vm.prank(ALICE);
        nftLending.claimCollateral(loanId);
        vm.stopPrank();
    }

    function testClaimCollateralCorrectlyTransfersCollateralNFT() public {
        // Initialize variables
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;
        uint256 tokenId = 1;

        // Create loan offer
        uint256 loanOfferId = _createLoanOffer(
            address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );

        // Accept loan offer
        vm.prank(BOB);
        uint256 loanId = nftLending.acceptLoanOffer(loanOfferId, tokenId);

        // Warp past loan duration
        vm.warp(block.timestamp + DEFAULT_DURATION + 1 seconds);

        // Claim collateral
        vm.prank(ALICE);
        nftLending.claimCollateral(loanId);

        // Assertions
        assertEq(mockERC721Two.balanceOf(address(nftLending)), 0);
        assertEq(mockERC721Two.balanceOf(ALICE), 1);
        assertEq(mockERC721Two.ownerOf(tokenId), ALICE);
        assertEq(mockERC721Two.balanceOf(BOB), 7);
    }
}
