// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {console} from "forge-std/console.sol";

contract NFTLending is Ownable2Step, ReentrancyGuard, Pausable, IERC721Receiver {
    using SafeERC20 for IERC20;

    /*////////////////////////////////////////////////////////////////
                                  ERRORS
    ////////////////////////////////////////////////////////////////*/

    error CollectionNotWhitelisted(address collection);
    error InvalidTreasuryAddress(address treasuryAddress);
    error InvalidWrappedNativeAddress(address wrappedNative);
    error InputParameterLengthMismatch();
    error LenderInsufficientWrappedNativeBalance(uint256 lenderBalance, uint256 requiredBalance);
    error LenderInsufficientWrappedNativeAllowance(uint256 lenderAllowance, uint256 requiredAllowance);
    error InvalidDuration();
    error InvalidInterestRate();
    error InvalidOfferExpiry(uint64 offerExpiry, uint256 currentTimestamp);
    error OfferInactive();
    error OfferExpired();
    error NFTCollectionMismatch(address expectedNftCollection, address providedNftCollection);
    error NotNFTOwner(address expectedNftOwner, address functionCaller);
    error NotLender(address expectedLender, address functionCaller);
    error NotBorrower(address expectedBorrower, address functionCaller);
    error LoanAlreadyRepaid();
    error LoanExpired(uint256 currentTimestamp, uint256 loanEndTimestamp);
    error CollateralAlreadyClaimed();
    error LoanNotExpired();
    error BatchLengthCannotBeZero();
    error BatchLimitExceeded(uint256 batchSize, uint256 batchLimit);

    /*////////////////////////////////////////////////////////////////
                            TYPE DECLERATIONS
    ////////////////////////////////////////////////////////////////*/

    struct LoanOffer {
        address lender;
        address nftCollection;
        uint96 principal;
        uint32 interestRateBps;
        uint64 loanDuration;
        uint64 offerExpiry;
        bool active;
    }

    struct Loan {
        address borrower;
        uint96 principal;
        address lender;
        uint96 fee;
        uint256 tokenId;
        address nftCollection;
        uint64 startTime;
        uint64 loanDuration;
        uint32 interestRateBps;
        bool repaid;
        bool collateralClaimed;
    }

    /*////////////////////////////////////////////////////////////////
                             STATE VARIABLES
    ////////////////////////////////////////////////////////////////*/

    uint256 private _nextOfferId;
    uint256 private _nextLoanId;
    address private _treasuryAddress;
    address private _wrappedNative;
    uint256 private _loanFeeBps;
    uint256 private _minLoanDuration;
    uint256 private _maxLoanDuration;
    uint256 private _minInterestRateBps;
    uint256 private _maxInterestRateBps;
    uint256 private _batchLimit;

    mapping(uint256 => LoanOffer) public loanOffers;
    mapping(uint256 => Loan) public loans;
    mapping(address => bool) public whitelistedCollections;

    /*////////////////////////////////////////////////////////////////
                                  EVENTS
    ////////////////////////////////////////////////////////////////*/

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

    /*////////////////////////////////////////////////////////////////
                                MODIFIERS
    ////////////////////////////////////////////////////////////////*/

    modifier onlyWhitelistedCollection(address collection) {
        if (!whitelistedCollections[collection]) {
            revert CollectionNotWhitelisted(collection);
        }
        _;
    }

    /*////////////////////////////////////////////////////////////////
                                FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    constructor(
        address treasuryAddress,
        address wrappedNative,
        uint256 loanFeeBps,
        uint256 minLoanDuration,
        uint256 maxLoanDuration,
        uint256 minInterestRateBps,
        uint256 maxInterestRateBps,
        uint256 batchLimit
    ) Ownable(msg.sender) {
        if (treasuryAddress == address(0)) {
            revert InvalidTreasuryAddress(treasuryAddress);
        }
        if (wrappedNative == address(0)) {
            revert InvalidWrappedNativeAddress(wrappedNative);
        }
        _treasuryAddress = treasuryAddress;
        _wrappedNative = wrappedNative;
        _loanFeeBps = loanFeeBps;
        _minLoanDuration = minLoanDuration;
        _maxLoanDuration = maxLoanDuration;
        _minInterestRateBps = minInterestRateBps;
        _maxInterestRateBps = maxInterestRateBps;
        _batchLimit = batchLimit;
    }

    /*////////////////////////////////////////////////////////////////
                            RECEIVE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function onERC721Received(address, address, uint256, bytes memory) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /*////////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function createLoanOffer(
        address nftCollection,
        uint96 principal,
        uint32 interestRateBps,
        uint64 loanDuration,
        uint64 offerExpiry
    ) external onlyWhitelistedCollection(nftCollection) nonReentrant returns (uint256) {
        return _createLoanOffer(nftCollection, principal, interestRateBps, loanDuration, offerExpiry);
    }

    function acceptLoanOffer(uint256 offerId, uint256 tokenId) external nonReentrant returns (uint256) {
        return _acceptLoanOffer(offerId, tokenId);
    }

    function cancelLoanOffer(uint256 offerId) external nonReentrant {
        _cancelLoanOffer(offerId);
    }

    function repayLoan(uint256 loanId) external nonReentrant {
        _repayLoan(loanId);
    }

    function claimCollateral(uint256 loanId) external nonReentrant {
        _claimCollateral(loanId);
    }

    function batchCreateLoanOffers(
        address nftCollection,
        uint96[] calldata principalAmounts,
        uint32[] calldata interestRatesBps,
        uint64[] calldata loanDurations,
        uint64[] calldata offerExpiries
    ) external nonReentrant returns (uint256[] memory) {
        uint256 numOffers = principalAmounts.length;

        _validateBatchSize(numOffers);

        if (
            numOffers != interestRatesBps.length || numOffers != loanDurations.length
                || numOffers != offerExpiries.length
        ) {
            revert InputParameterLengthMismatch();
        }

        uint256 totalPrincipalAmount;
        for (uint256 i = 0; i < numOffers; i++) {
            totalPrincipalAmount += principalAmounts[i];
        }

        uint256 lenderBalance = IERC20(_wrappedNative).balanceOf(msg.sender);
        if (totalPrincipalAmount > lenderBalance) {
            revert LenderInsufficientWrappedNativeBalance(lenderBalance, totalPrincipalAmount);
        }

        uint256 lenderAllowance = IERC20(_wrappedNative).allowance(msg.sender, address(this));
        if (totalPrincipalAmount > lenderAllowance) {
            revert LenderInsufficientWrappedNativeAllowance(lenderAllowance, totalPrincipalAmount);
        }

        uint256[] memory loanOfferIds = new uint256[](numOffers);

        for (uint256 i = 0; i < numOffers; i++) {
            loanOfferIds[i] = _createLoanOffer(
                nftCollection, principalAmounts[i], interestRatesBps[i], loanDurations[i], offerExpiries[i]
            );
        }

        return loanOfferIds;
    }

    function batchAcceptLoanOffers(uint256[] calldata offerIds, uint256[] calldata tokenIds)
        external
        nonReentrant
        returns (uint256[] memory)
    {
        _validateBatchSize(offerIds.length);

        if (offerIds.length != tokenIds.length) {
            revert InputParameterLengthMismatch();
        }

        uint256[] memory loanIds = new uint256[](offerIds.length);

        for (uint256 i = 0; i < offerIds.length; i++) {
            loanIds[i] = _acceptLoanOffer(offerIds[i], tokenIds[i]);
        }
        return loanIds;
    }

    function batchCancelLoanOffers(uint256[] calldata offerIds) external nonReentrant {
        _validateBatchSize(offerIds.length);

        for (uint256 i = 0; i < offerIds.length; i++) {
            _cancelLoanOffer(offerIds[i]);
        }
    }

    function batchRepayLoans(uint256[] calldata loanIds) external nonReentrant {
        _validateBatchSize(loanIds.length);

        for (uint256 i = 0; i < loanIds.length; i++) {
            _repayLoan(loanIds[i]);
        }
    }

    function batchClaimCollateral(uint256[] calldata loanIds) external nonReentrant {
        _validateBatchSize(loanIds.length);

        for (uint256 i = 0; i < loanIds.length; i++) {
            _claimCollateral(loanIds[i]);
        }
    }

    function setCollectionWhitelisted(address collection, bool status) external onlyOwner {
        whitelistedCollections[collection] = status;
    }

    function setLoanFeeBps(uint256 loanFeeBps) external onlyOwner {
        _loanFeeBps = loanFeeBps;
    }

    function setMinLoanDuration(uint256 minLoanDuration) external onlyOwner {
        _minLoanDuration = minLoanDuration;
    }

    function setMaxLoanDuration(uint256 maxLoanDuration) external onlyOwner {
        _maxLoanDuration = maxLoanDuration;
    }

    function setMinInterestRate(uint256 minInterestRateBps) external onlyOwner {
        _minInterestRateBps = minInterestRateBps;
    }

    function setMaxInterestRate(uint256 maxInterestRateBps) external onlyOwner {
        _maxInterestRateBps = maxInterestRateBps;
    }

    function setTreasuryAddress(address treasuryAddress) external onlyOwner {
        _treasuryAddress = treasuryAddress;
    }

    function setBatchLimit(uint256 batchLimit) external onlyOwner {
        _batchLimit = batchLimit;
    }

    /*////////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function _createLoanOffer(
        address nftCollection,
        uint96 principal,
        uint32 interestRateBps,
        uint64 loanDuration,
        uint64 offerExpiry
    ) internal returns (uint256) {
        if (loanDuration < _minLoanDuration || loanDuration > _maxLoanDuration) {
            revert InvalidDuration();
        }
        if (interestRateBps < _minInterestRateBps || interestRateBps > _maxInterestRateBps) {
            revert InvalidInterestRate();
        }
        if (block.timestamp > offerExpiry) {
            revert InvalidOfferExpiry(offerExpiry, block.timestamp);
        }

        uint256 lenderBalance = IERC20(_wrappedNative).balanceOf(msg.sender);
        if (principal > lenderBalance) {
            revert LenderInsufficientWrappedNativeBalance(lenderBalance, principal);
        }

        uint256 lenderAllowance = IERC20(_wrappedNative).allowance(msg.sender, address(this));
        if (principal > lenderAllowance) {
            revert LenderInsufficientWrappedNativeAllowance(lenderAllowance, principal);
        }

        uint256 offerId = _nextOfferId;

        loanOffers[offerId] = LoanOffer({
            lender: msg.sender,
            nftCollection: nftCollection,
            principal: principal,
            interestRateBps: interestRateBps,
            loanDuration: loanDuration,
            offerExpiry: offerExpiry,
            active: true
        });

        _nextOfferId++;
        emit LoanOfferCreated(offerId, msg.sender, nftCollection, interestRateBps, loanDuration, offerExpiry);

        return offerId;
    }

    function _acceptLoanOffer(uint256 offerId, uint256 tokenId) internal returns (uint256) {
        LoanOffer storage loanOffer = loanOffers[offerId];

        if (!loanOffer.active) {
            revert OfferInactive();
        }

        if (block.timestamp > loanOffer.offerExpiry) {
            revert OfferExpired();
        }

        address nftCollection = loanOffer.nftCollection;
        address nftOwner = IERC721(nftCollection).ownerOf(tokenId);
        if (nftOwner != msg.sender) {
            revert NotNFTOwner(nftOwner, msg.sender);
        }

        uint256 loanId = _nextLoanId;
        address lender = loanOffer.lender;
        uint96 principal = loanOffer.principal;
        uint256 fee = _calculateLoanFee(principal);
        uint256 loanAmountAfterFee = _calculateLoanAmountAfterFee(principal, fee);

        loans[loanId] = Loan({
            borrower: msg.sender,
            principal: principal,
            lender: lender,
            fee: uint96(fee),
            tokenId: tokenId,
            nftCollection: nftCollection,
            startTime: uint64(block.timestamp),
            loanDuration: loanOffer.loanDuration,
            interestRateBps: loanOffer.interestRateBps,
            repaid: false,
            collateralClaimed: false
        });

        loanOffer.active = false;
        _nextLoanId++;
        emit LoanAccepted(loanId, offerId, msg.sender, tokenId);

        IERC721(nftCollection).safeTransferFrom(msg.sender, address(this), tokenId);
        IERC20(_wrappedNative).safeTransferFrom(lender, msg.sender, loanAmountAfterFee);
        IERC20(_wrappedNative).safeTransferFrom(lender, _treasuryAddress, fee);

        return loanId;
    }

    function _cancelLoanOffer(uint256 offerId) internal {
        LoanOffer storage loanOffer = loanOffers[offerId];

        if (!loanOffer.active) {
            revert OfferInactive();
        }

        address lender = loanOffer.lender;
        if (lender != msg.sender) {
            revert NotLender(lender, msg.sender);
        }

        loanOffer.active = false;
        emit LoanOfferCanceled(offerId, msg.sender);
    }

    function _repayLoan(uint256 loanId) internal {
        Loan storage loan = loans[loanId];

        if (loan.repaid) {
            revert LoanAlreadyRepaid();
        }

        address borrower = loan.borrower;
        if (borrower != msg.sender) {
            revert NotBorrower(borrower, msg.sender);
        }

        uint256 loanStartTime = loan.startTime;
        uint256 loanEndTimestamp = loanStartTime + loan.loanDuration;
        if (block.timestamp > loanEndTimestamp) {
            revert LoanExpired(block.timestamp, loanEndTimestamp);
        }

        uint96 principal = loan.principal;
        uint256 duration = block.timestamp - loanStartTime;
        uint256 interest = _calculateInterest(principal, loan.interestRateBps, duration);
        uint256 totalRepayment = _calculateTotalRepayment(principal, interest);

        loan.repaid = true;
        emit LoanRepaid(loanId, borrower);

        IERC721(loan.nftCollection).safeTransferFrom(address(this), borrower, loan.tokenId);
        IERC20(_wrappedNative).safeTransferFrom(borrower, loan.lender, totalRepayment);
    }

    function _claimCollateral(uint256 loanId) internal {
        Loan storage loan = loans[loanId];

        if (loan.repaid) {
            revert LoanAlreadyRepaid();
        }
        if (loan.collateralClaimed) {
            revert CollateralAlreadyClaimed();
        }
        if (block.timestamp <= loan.startTime + loan.loanDuration) {
            revert LoanNotExpired();
        }

        address lender = loan.lender;
        if (lender != msg.sender) {
            revert NotLender(lender, msg.sender);
        }

        loan.collateralClaimed = true;
        emit CollateralClaimed(loanId, msg.sender);

        IERC721(loan.nftCollection).safeTransferFrom(address(this), lender, loan.tokenId);
    }

    /*////////////////////////////////////////////////////////////////
                      INTERNAL VIEW & PURE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function _validateBatchSize(uint256 batchSize) internal view {
        if (batchSize == 0) {
            revert BatchLengthCannotBeZero();
        }
        if (batchSize > _batchLimit) {
            revert BatchLimitExceeded(batchSize, _batchLimit);
        }
    }

    function _calculateLoanFee(uint256 principal) internal view returns (uint256) {
        return (principal * _loanFeeBps) / 10000;
    }

    function _calculateInterest(uint256 principal, uint256 interestRateBps, uint256 duration)
        internal
        pure
        returns (uint256)
    {
        return (principal * interestRateBps * duration) / (10000 * 365 days);
    }

    function _calculateLoanAmountAfterFee(uint256 principal, uint256 fee) internal pure returns (uint256) {
        return principal - fee;
    }

    function _calculateTotalRepayment(uint256 principal, uint256 interest) internal pure returns (uint256) {
        return principal + interest;
    }

    /*////////////////////////////////////////////////////////////////
                      EXTERNAL VIEW & PURE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    function getLoanOfferCount() external view returns (uint256) {
        return _nextOfferId;
    }

    function getLoanCount() external view returns (uint256) {
        return _nextLoanId;
    }

    function getLoanDetails(uint256 loanId) external view returns (Loan memory) {
        return loans[loanId];
    }

    function getLoanOffer(uint256 offerId) external view returns (LoanOffer memory) {
        return loanOffers[offerId];
    }

    function isCollectionWhitelisted(address collection) external view returns (bool) {
        return whitelistedCollections[collection];
    }

    function getLoanFeeBps() external view returns (uint256) {
        return _loanFeeBps;
    }

    function getMinLoanDuration() external view returns (uint256) {
        return _minLoanDuration;
    }

    function getMaxLoanDuration() external view returns (uint256) {
        return _maxLoanDuration;
    }

    function getMinInterestRate() external view returns (uint256) {
        return _minInterestRateBps;
    }

    function getMaxInterestRate() external view returns (uint256) {
        return _maxInterestRateBps;
    }

    function getBatchLimit() external view returns (uint256) {
        return _batchLimit;
    }
}
