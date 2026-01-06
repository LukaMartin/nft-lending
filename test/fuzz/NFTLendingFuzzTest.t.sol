// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {NFTLending} from "src/NFTLending.sol";
import {BaseTest} from "test/BaseTest.t.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

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
            loanDurations[i] = DEFAULT_DURATION;
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

    function _batchAcceptLoanOffers(uint256[] memory loanOfferIds) internal returns (uint256[] memory) {
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

    function testFuzzCreateLoanOfferRevertsWhenDurationIsLessThanMinDuration(uint64 duration) public {
        // Initialize variables
        duration = uint64(bound(duration, 1 seconds, minLoanDuration - 1 seconds));
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

    function testFuzzCreateLoanOfferRevertsWhenInterestRateIsLessThanMinInterestRate(uint32 interestRateBps) public {
        // Initialize variables
        interestRateBps = uint32(bound(interestRateBps, 1, minInterestRateBps - 1));
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

    function testFuzzCreateLoanOfferRevertsWhenInterestRateIsGreaterThanMaxInterestRate(uint32 interestRateBps) public {
        // Initialize variables
        interestRateBps = uint32(bound(interestRateBps, maxInterestRateBps + 1, type(uint32).max));
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

    function testFuzzCreateLoanOfferRevertsWhenDurationIsGreaterThanMaxDuration(uint64 duration) public {
        // Initialize variables
        duration = uint64(bound(duration, maxLoanDuration + 1 seconds, type(uint64).max - uint64(block.timestamp)));
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

    function testFuzzCreateLoanOfferRevertsWhenOfferExpiryIsInThePast(uint64 timeInThePast) public {
        // Initialize variables
        timeInThePast = uint64(bound(timeInThePast, 1 seconds, 10000 days));
        uint64 offerExpiry = uint64(block.timestamp) - timeInThePast;

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

    function testFuzzCreateLoanOfferRevertsWhenLenderInsufficientWrappedNativeBalance(uint96 principal) public {
        // Initialize variables
        principal = uint96(bound(principal, 1 wei, 10 ether - 1 wei));
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

    function testFuzzCreateLoanOfferRevertsWhenLenderInsufficientWrappedNativeAllowance(uint96 principal) public {
        // Initialize variables
        principal = uint96(bound(principal, 1 wei, 10 ether));
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

    function testFuzzCreateLoanOfferAndAssertLoanOfferDetails(
        uint96 principal,
        uint32 interestRateBps,
        uint64 loanDuration,
        uint64 expiry
    ) public {
        // Get current loan offer count
        uint256 loanOfferCount = nftLending.getLoanOfferCount();

        // Initialize variables
        principal = uint96(bound(principal, 0.01 ether, 10000 ether));
        interestRateBps = uint32(bound(interestRateBps, minInterestRateBps, maxInterestRateBps));
        loanDuration = uint64(bound(loanDuration, minLoanDuration, maxLoanDuration));
        expiry = uint64(bound(expiry, 1 seconds, 1000 days));
        uint64 offerExpiry = uint64(block.timestamp) + expiry;

        // Deal Alice principal amount
        vm.deal(ALICE, principal);

        // Create loan offer
        uint256 loanOfferId =
            _createLoanOffer(address(mockERC721One), principal, interestRateBps, loanDuration, offerExpiry);

        // Get loan offer
        NFTLending.LoanOffer memory loanOffer = nftLending.getLoanOffer(loanOfferId);

        // Assertions
        assertEq(loanOfferCount, loanOfferId);
        assertEq(loanOffer.lender, ALICE);
        assertEq(loanOffer.nftCollection, address(mockERC721One));
        assertEq(loanOffer.principal, principal);
        assertEq(loanOffer.interestRateBps, interestRateBps);
        assertEq(loanOffer.loanDuration, loanDuration);
        assertEq(loanOffer.offerExpiry, offerExpiry);
        assertEq(loanOffer.active, true);
    }

    function testFuzzBatchCreateLoanOffersRevertsWhenBatchSizeExceedsLimit(uint256 batchSize) public {
        // Initialize variables
        batchSize = bound(batchSize, nftLending.getBatchLimit() + 1, 10000);
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

    function testFuzzBatchCreateLoanOffersRevertsWhenLenderInsufficientWrappedNativeBalance(uint256 principalDeficit)
        public
    {
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

        // Bound principal deficit to be less than total principal amount
        principalDeficit = bound(principalDeficit, 1 wei, totalPrincipalAmount - 1 wei);

        vm.startPrank(ALICE);
        // Deposit insufficient wrapped native balance
        mockWrappedNative.deposit{value: totalPrincipalAmount - principalDeficit}(); // Deposit less than total principal amount
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

    function testFuzzBatchCreateLoanOffersRevertsWhenLenderInsufficientWrappedNativeAllowance(uint256 principalDeficit)
        public
    {
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

        // Bound principal deficit to be less than total principal amount
        principalDeficit = bound(principalDeficit, 1 wei, totalPrincipalAmount - 1 wei);

        vm.startPrank(ALICE);
        // Approve insufficient wrapped native allowance
        mockWrappedNative.deposit{value: totalPrincipalAmount}();
        mockWrappedNative.approve(address(nftLending), totalPrincipalAmount - principalDeficit); // Approve less than total principal amount
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

    function testFuzzBatchCreateLoanOffersCorrectlyCreatesLoanOffers(
        uint256 numOffers,
        uint96 principal,
        uint32 interestRateBps,
        uint64 loanDuration,
        uint64 expiry
    ) public {
        // Initialize variables
        numOffers = bound(numOffers, 1, nftLending.getBatchLimit());
        principal = uint96(bound(principal, 0.01 ether, 10000 ether));
        interestRateBps = uint32(bound(interestRateBps, minInterestRateBps, maxInterestRateBps));
        loanDuration = uint64(bound(loanDuration, minLoanDuration, maxLoanDuration));
        expiry = uint64(bound(expiry, 1 seconds, 1000 days));
        uint64 offerExpiry = uint64(block.timestamp) + expiry;
        uint256 preOfferCount = nftLending.getLoanOfferCount();

        uint96[] memory principalAmounts = new uint96[](numOffers);
        uint32[] memory interestRatesBps = new uint32[](numOffers);
        uint64[] memory loanDurations = new uint64[](numOffers);
        uint64[] memory offerExpiries = new uint64[](numOffers);
        uint256 totalPrincipalAmount = 0;

        for (uint256 i = 0; i < numOffers; i++) {
            principalAmounts[i] = principal;
            totalPrincipalAmount += principal;
            interestRatesBps[i] = interestRateBps;
            loanDurations[i] = loanDuration;
            offerExpiries[i] = offerExpiry;
        }

        // Deal Alice principal amount
        vm.deal(ALICE, totalPrincipalAmount);

        vm.startPrank(ALICE);
        // Deposit wrapped native, and approve NFTLending to spend
        mockWrappedNative.deposit{value: totalPrincipalAmount}();
        mockWrappedNative.approve(address(nftLending), totalPrincipalAmount);
        // Create loan offers
        uint256[] memory loanOfferIds = nftLending.batchCreateLoanOffers(
            address(mockERC721One), principalAmounts, interestRatesBps, loanDurations, offerExpiries
        );
        vm.stopPrank();

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

    function testFuzzAcceptLoanOfferRevertsWhenOfferIsExpired(uint256 expiryTime) public {
        // Initialize variables
        expiryTime = bound(expiryTime, 1 seconds, 10000 days);
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;
        uint256 tokenId = 1;

        // Create loan offer
        uint256 loanOfferId = _createLoanOffer(
            address(mockERC721Two), DEFAULT_PRINCIPAL, DEFAULT_INTEREST_RATE_BPS, DEFAULT_DURATION, offerExpiry
        );

        // Warp past offer expiry
        vm.warp(offerExpiry + expiryTime);

        // Try to accept loan offer
        vm.prank(BOB);
        vm.expectRevert(NFTLending.OfferExpired.selector);
        nftLending.acceptLoanOffer(loanOfferId, tokenId);
    }

    function testFuzzAcceptLoanOfferCorrectlyCreatesLoan(
        uint96 principal,
        uint32 interestRateBps,
        uint64 loanDuration,
        uint64 expiry,
        uint256 tokenId
    ) public {
        // Initialize variables
        principal = uint96(bound(principal, 0.01 ether, 10000 ether));
        interestRateBps = uint32(bound(interestRateBps, minInterestRateBps, maxInterestRateBps));
        loanDuration = uint64(bound(loanDuration, minLoanDuration, maxLoanDuration));
        expiry = uint64(bound(expiry, 1 seconds, 1000 days));
        tokenId = bound(tokenId, 1, 8);
        uint64 offerExpiry = uint64(block.timestamp) + expiry;
        uint256 loanFee = _calculateLoanFee(principal);
        uint256 loanAmountAfterFee = principal - loanFee;
        uint256 bobInitialNFTBalance = mockERC721Two.balanceOf(BOB);

        // Deal Alice principal amount
        vm.deal(ALICE, principal);

        // Create loan offer
        uint256 loanOfferId =
            _createLoanOffer(address(mockERC721Two), principal, interestRateBps, loanDuration, offerExpiry);

        // Get pre-balances
        uint256 preBobBalance = mockWrappedNative.balanceOf(BOB);
        uint256 preAliceBalance = mockWrappedNative.balanceOf(ALICE);

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
        assertEq(loan.principal, principal);
        assertEq(loan.interestRateBps, interestRateBps);
        assertEq(loan.loanDuration, loanDuration);
        assertEq(loan.fee, _calculateLoanFee(principal));
        assertEq(loan.repaid, false);
        assertEq(loan.collateralClaimed, false);
        assertEq(loanOffer.active, false);
        assertEq(mockERC721Two.balanceOf(address(nftLending)), 1);
        assertEq(mockERC721Two.balanceOf(BOB), bobInitialNFTBalance - 1);
        assertEq(mockERC721Two.ownerOf(tokenId), address(nftLending));
        assertEq(mockWrappedNative.balanceOf(BOB), preBobBalance + loanAmountAfterFee);
        assertEq(mockWrappedNative.balanceOf(ALICE), preAliceBalance - principal);
        assertEq(mockWrappedNative.balanceOf(treasury), loanFee);
    }

    function testFuzzAcceptLoanOfferIncrementsNextLoanId(uint256 numLoans) public {
        // Initialize variables
        numLoans = bound(numLoans, 1, mockERC721Two.balanceOf(BOB));

        // Create loan offer
        (uint256[] memory loanOfferIds,,,,) = _batchCreateLoanOffers(numLoans, address(mockERC721Two));

        // Accept loan offer
        vm.startPrank(BOB);
        for (uint256 i = 0; i < numLoans; i++) {
            uint256 loanId = nftLending.acceptLoanOffer(loanOfferIds[i], i + 1);
            assertEq(nftLending.getLoanCount(), loanId + 1);
        }
        vm.stopPrank();
    }

    function testFuzzBatchAcceptLoanOffersCorrectlyAcceptsLoanOffers(uint256 numOffers) public {
        // Initialize variables
        numOffers = bound(numOffers, 1, mockERC721Two.balanceOf(BOB));
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
        }
    }

    /*////////////////////////////////////////////////////////////////
                         CANCEL LOAN OFFER TESTS
    ////////////////////////////////////////////////////////////////*/

    function testFuzzBatchCancelLoanOffersCorrectlyCancelsLoanOffers(uint256 numOffers) public {
        // Initialize variables
        numOffers = bound(numOffers, 1, nftLending.getBatchLimit());

        // Create loan offers
        (uint256[] memory loanOfferIds,,,,) = _batchCreateLoanOffers(numOffers, address(mockERC721Two));

        vm.prank(ALICE);
        nftLending.batchCancelLoanOffers(loanOfferIds);

        // Assertions
        for (uint256 i = 0; i < numOffers; i++) {
            NFTLending.LoanOffer memory loanOffer = nftLending.getLoanOffer(loanOfferIds[i]);
            assertEq(loanOffer.active, false);
        }
    }

    /*////////////////////////////////////////////////////////////////
                          REPAY LOAN OFFER TESTS
    ////////////////////////////////////////////////////////////////*/

    function testFuzzRepayLoanRevertsWhenLoanIsExpired(uint256 expiryTime) public {
        // Initialize variables
        expiryTime = bound(expiryTime, 1 seconds, 10000 days);
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
        uint256 warpTimestamp = loanEndTimestamp + expiryTime;

        // Skip just over 30 days
        vm.warp(warpTimestamp);

        // Try to repay loan
        vm.expectRevert(abi.encodeWithSelector(NFTLending.LoanExpired.selector, block.timestamp, loanEndTimestamp));
        nftLending.repayLoan(loanId);

        vm.stopPrank();
    }

    function testFuzzRepayLoanCorrectlyTransfersNFTAndWrappedNativeTokensForEarlyRepayment(uint256 duration) public {
        // Initialize variables
        duration = bound(duration, 1 seconds, DEFAULT_DURATION);
        uint64 offerExpiry = uint64(block.timestamp) + DEFAULT_OFFER_EXPIRY;
        uint256 tokenId = 1;
        uint256 bobInitialMockNFTBalance = mockERC721Two.balanceOf(BOB);

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
        vm.warp(block.timestamp + duration);

        // Repay loan
        (, uint256 interest) = _repayLoan(loanId, BOB, duration);
        vm.stopPrank();

        // Assertions
        assertEq(mockERC721Two.balanceOf(address(nftLending)), 0);
        assertEq(mockERC721Two.balanceOf(BOB), bobInitialMockNFTBalance);
        assertEq(mockERC721Two.ownerOf(tokenId), BOB);
        assertEq(mockWrappedNative.balanceOf(BOB), 0);
        assertEq(mockWrappedNative.balanceOf(ALICE), preAliceBalance + interest);
    }

    function testFuzzBatchRepayLoansCorrectlyRepaysLoans(uint256 numOffers) public {
        // Initialize variables
        numOffers = bound(numOffers, 1, mockERC721Two.balanceOf(BOB));
        uint256 bobInitialMockNFTBalance = mockERC721Two.balanceOf(BOB);

        // Create loans
        (
            uint256[] memory loanOfferIds,
            uint96[] memory principalAmounts,
            uint32[] memory interestRatesBps,
            uint64[] memory loanDurations,
        ) = _batchCreateLoanOffers(numOffers, address(mockERC721Two));

        // Accept loan offers
        uint256[] memory loanIds = _batchAcceptLoanOffers(loanOfferIds);

        // Calculate total repayment amount
        uint256 totalRepayment = 0;
        for (uint256 i = 0; i < numOffers; i++) {
            uint256 interest = _calculateInterest(principalAmounts[i], interestRatesBps[i], loanDurations[i]);
            totalRepayment += principalAmounts[i] + interest;
        }

        // Get pre-balances
        uint256 preBobBalance = mockWrappedNative.balanceOf(BOB);
        uint256 preAliceBalance = mockWrappedNative.balanceOf(ALICE);

        // Warp loan duration
        vm.warp(block.timestamp + DEFAULT_DURATION);

        // Repay loans
        vm.startPrank(BOB);
        mockWrappedNative.deposit{value: totalRepayment - preBobBalance}();
        mockWrappedNative.approve(address(nftLending), totalRepayment);
        nftLending.batchRepayLoans(loanIds);
        vm.stopPrank();

        // Assertions
        for (uint256 i = 0; i < numOffers; i++) {
            NFTLending.Loan memory loan = nftLending.getLoanDetails(loanIds[i]);
            assertEq(loan.repaid, true);
            assertEq(mockERC721Two.ownerOf(loan.tokenId), BOB);
        }

        assertEq(mockWrappedNative.balanceOf(ALICE), totalRepayment + preAliceBalance);
        assertEq(mockWrappedNative.balanceOf(BOB), 0);
        assertEq(mockERC721Two.balanceOf(BOB), bobInitialMockNFTBalance);
        assertEq(mockERC721Two.balanceOf(address(nftLending)), 0);
    }

    /*////////////////////////////////////////////////////////////////
                          CLAIM COLLATERAL TESTS
    ////////////////////////////////////////////////////////////////*/

    function testFuzzClaimCollateralRevertsWhenLoanIsNotExpired(uint256 duration) public {
        // Initialize variables
        duration = bound(duration, 1 seconds, DEFAULT_DURATION - 1 seconds);
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

        // Warp right up to loan duration
        vm.warp(block.timestamp + duration);

        // Try to claim collateral
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(NFTLending.LoanNotExpired.selector, block.timestamp, loanEndTimestamp));
        nftLending.claimCollateral(loanId);
    }

    function testFuzzBatchClaimCollateralCorrectlyClaimsCollateral(uint256 numOffers, uint256 timePastDuration) public {
        // Initialize variables
        numOffers = bound(numOffers, 1, mockERC721Two.balanceOf(BOB));
        timePastDuration = bound(timePastDuration, 1 seconds, 10000 days);
        uint256 aliceInitialNFTBalance = mockERC721Two.balanceOf(ALICE);
        uint256 bobInitialNFTBalance = mockERC721Two.balanceOf(BOB);

        // Create loan offers
        (uint256[] memory loanOfferIds,,,,) = _batchCreateLoanOffers(numOffers, address(mockERC721Two));

        // Accept loan offers
        uint256[] memory loanIds = _batchAcceptLoanOffers(loanOfferIds);

        // Warp past loan duration
        vm.warp(block.timestamp + DEFAULT_DURATION + timePastDuration);

        // Batch claim collateral
        vm.prank(ALICE);
        nftLending.batchClaimCollateral(loanIds);

        // Assertions
        for (uint256 i = 0; i < numOffers; i++) {
            NFTLending.Loan memory loan = nftLending.getLoanDetails(loanIds[i]);
            assertEq(loan.collateralClaimed, true);
            assertEq(mockERC721Two.ownerOf(loan.tokenId), ALICE);
        }

        assertEq(mockERC721Two.balanceOf(address(nftLending)), 0);
        assertEq(mockERC721Two.balanceOf(ALICE), aliceInitialNFTBalance + numOffers);
        assertEq(mockERC721Two.balanceOf(BOB), bobInitialNFTBalance - numOffers);
    }
}
