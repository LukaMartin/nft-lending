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

    function testFuzzCreateLoanOfferRevertsWhenCollectionIsNotWhitelisted(address nftCollection) public {
        // Initialize variables
        vm.assume(nftCollection != address(mockERC721One));
        vm.assume(nftCollection != address(mockERC721Two));
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
        batchSize = uint256(bound(batchSize, nftLending.getBatchLimit() + 1, 10000));
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

    function testBatchCreateLoanOffersRevertsWhenLenderInsufficientWrappedNativeBalance(uint256 principalDeficit)
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
        principalDeficit = uint256(bound(principalDeficit, 1 wei, totalPrincipalAmount - 1 wei));

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
        principalDeficit = uint256(bound(principalDeficit, 1 wei, totalPrincipalAmount - 1 wei));

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
        numOffers = uint256(bound(numOffers, 1, nftLending.getBatchLimit()));
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
        expiryTime = uint256(bound(expiryTime, 1 seconds, 10000 days));
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
        tokenId = uint256(bound(tokenId, 1, 8));
        uint64 offerExpiry = uint64(block.timestamp) + expiry;

        // Deal Alice principal amount
        vm.deal(ALICE, principal);

        // Create loan offer
        uint256 loanOfferId =
            _createLoanOffer(address(mockERC721Two), principal, interestRateBps, loanDuration, offerExpiry);

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
    }
}
