// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title NFTLending
 * @author luka_martin
 * @notice An on-chain peer-to-peer NFT-collateralized lending protocol.
 *         Lenders create offers specifying terms. Borrowers accept by depositing NFT collateral.
 *         Interest is calculated pro-rata based on actual loan duration. If the borrower defaults,
 *         the lender can claim the NFT collateral.
 */
contract NFTLending is Ownable2Step, ReentrancyGuard, IERC721Receiver {
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
        uint256 indexed offerId,
        address indexed lender,
        address indexed nftCollection,
        uint256 interestRate,
        uint64 loanDuration,
        uint64 offerExpiry
    );
    event LoanAccepted(uint256 indexed loanId, uint256 indexed offerId, address indexed borrower, uint256 tokenId);
    event LoanRepaid(uint256 indexed loanId, address indexed borrower);
    event CollateralClaimed(uint256 indexed loanId, address indexed lender);
    event LoanOfferCanceled(uint256 indexed offerId, address indexed lender);
    event CollectionWhitelisted(address indexed collection, bool status);
    event LoanFeeBpsSet(uint256 loanFeeBps);
    event MinLoanDurationSet(uint256 minLoanDuration);
    event MaxLoanDurationSet(uint256 maxLoanDuration);
    event MinInterestRateSet(uint256 minInterestRateBps);
    event MaxInterestRateSet(uint256 maxInterestRateBps);
    event TreasuryAddressSet(address treasuryAddress);
    event BatchLimitSet(uint256 batchLimit);

    /*////////////////////////////////////////////////////////////////
                                MODIFIERS
    ////////////////////////////////////////////////////////////////*/

    /**
     * @notice Restricts function to only accept whitelisted NFT collections
     * @param collection The NFT collection address to validate
     */
    modifier onlyWhitelistedCollection(address collection) {
        if (!whitelistedCollections[collection]) {
            revert CollectionNotWhitelisted(collection);
        }
        _;
    }

    /*////////////////////////////////////////////////////////////////
                                FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /**
     * @notice Constructor for the NFTLending contract
     * @param treasuryAddress Address that receives protocol fees
     * @param wrappedNative Address of the wrapped native token (e.g., WETH)
     * @param loanFeeBps Protocol fee in basis points charged on each loan
     * @param minLoanDuration Minimum allowed loan duration in seconds
     * @param maxLoanDuration Maximum allowed loan duration in seconds
     * @param minInterestRateBps Minimum allowed annual interest rate in basis points
     * @param maxInterestRateBps Maximum allowed annual interest rate in basis points
     * @param batchLimit Maximum number of operations allowed in batch functions
     */
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

    /**
     * @notice Handles the receipt of an NFT
     * @dev Required for the contract to receive ERC721 tokens via safeTransferFrom
     * @return bytes4 Returns the function selector to confirm the transfer
     */
    function onERC721Received(address, address, uint256, bytes memory) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /*////////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates a loan offer for a whitelisted NFT collection
     * @dev Caller must have approved sufficient wrapped native tokens for the principal amount
     * @param nftCollection Address of the NFT collection to accept as collateral
     * @param principal Amount of wrapped native tokens to lend
     * @param interestRateBps Annual interest rate in basis points (e.g., 1000 = 10%)
     * @param loanDuration Duration of the loan in seconds
     * @param offerExpiry Timestamp when the offer expires
     * @return offerId The ID of the created loan offer
     */
    function createLoanOffer(
        address nftCollection,
        uint96 principal,
        uint32 interestRateBps,
        uint64 loanDuration,
        uint64 offerExpiry
    ) external onlyWhitelistedCollection(nftCollection) nonReentrant returns (uint256) {
        return _createLoanOffer(nftCollection, principal, interestRateBps, loanDuration, offerExpiry);
    }

    /**
     * @notice Accepts a loan offer for a specific offer ID by providing an NFT as collateral
     * @dev Caller must own the NFT and have approved this contract to transfer it
     * @param offerId The ID of the loan offer to accept
     * @param tokenId The token ID of the NFT to use as collateral
     * @return loanId The ID of the created loan
     */
    function acceptLoanOffer(uint256 offerId, uint256 tokenId) external nonReentrant returns (uint256) {
        return _acceptLoanOffer(offerId, tokenId);
    }

    /**
     * @notice Cancels an active loan offer
     * @dev Only the lender who created the offer can cancel it
     * @param offerId The ID of the loan offer to cancel
     */
    function cancelLoanOffer(uint256 offerId) external nonReentrant {
        _cancelLoanOffer(offerId);
    }

    /**
     * @notice Repays an active loan and returns the collateral NFT to the borrower
     * @dev Caller must be the borrower and have approved sufficient tokens for repayment
     * @param loanId The ID of the loan to repay
     */
    function repayLoan(uint256 loanId) external nonReentrant {
        _repayLoan(loanId);
    }

    /**
     * @notice Claims the collateral NFT from a defaulted loan and transfers it to the lender
     * @dev Only callable by the lender after the loan has expired without repayment
     * @param loanId The ID of the defaulted loan
     */
    function claimCollateral(uint256 loanId) external nonReentrant {
        _claimCollateral(loanId);
    }

    /**
     * @notice Creates multiple loan offers in a single transaction
     * @dev All arrays must have the same length. Caller must have approved total principal amount
     * @param nftCollection Address of the NFT collection for all offers
     * @param principalAmounts Array of principal amounts for each offer
     * @param interestRatesBps Array of interest rates in basis points for each offer
     * @param loanDurations Array of loan durations in seconds for each offer
     * @param offerExpiries Array of expiry timestamps for each offer
     * @return loanOfferIds Array of created loan offer IDs
     */
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

        uint256 totalPrincipalAmount = 0;
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

    /**
     * @notice Accepts multiple loan offers in a single transaction
     * @dev Arrays must have the same length. Caller must own all NFTs and have approved transfers
     * @param offerIds Array of loan offer IDs to accept
     * @param tokenIds Array of NFT token IDs to use as collateral
     * @return loanIds Array of created loan IDs
     */
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

    /**
     * @notice Cancels multiple loan offers in a single transaction
     * @dev Caller must be the lender for all offers
     * @param offerIds Array of loan offer IDs to cancel
     */
    function batchCancelLoanOffers(uint256[] calldata offerIds) external nonReentrant {
        _validateBatchSize(offerIds.length);

        for (uint256 i = 0; i < offerIds.length; i++) {
            _cancelLoanOffer(offerIds[i]);
        }
    }

    /**
     * @notice Repays multiple loans in a single transaction
     * @dev Caller must be the borrower for all loans and have approved total repayment amount
     * @param loanIds Array of loan IDs to repay
     */
    function batchRepayLoans(uint256[] calldata loanIds) external nonReentrant {
        _validateBatchSize(loanIds.length);

        for (uint256 i = 0; i < loanIds.length; i++) {
            _repayLoan(loanIds[i]);
        }
    }

    /**
     * @notice Claims collateral from multiple defaulted loans in a single transaction
     * @dev Caller must be the lender for all loans and all loans must be expired
     * @param loanIds Array of defaulted loan IDs to claim collateral from
     */
    function batchClaimCollateral(uint256[] calldata loanIds) external nonReentrant {
        _validateBatchSize(loanIds.length);

        for (uint256 i = 0; i < loanIds.length; i++) {
            _claimCollateral(loanIds[i]);
        }
    }

    /**
     * @notice Sets the whitelist status for an NFT collection. Only whitelisted collections can be used as collateral.
     * @dev This is only callable by the owner
     * @param collection Address of the NFT collection
     * @param status True to whitelist, false to remove from whitelist
     */
    function setCollectionWhitelisted(address collection, bool status) external onlyOwner {
        whitelistedCollections[collection] = status;
        emit CollectionWhitelisted(collection, status);
    }

    /**
     * @notice Sets the protocol fee charged on each loan
     * @dev This is only callable by the owner
     * @param loanFeeBps Fee in basis points (e.g., 100 = 1%)
     */
    function setLoanFeeBps(uint256 loanFeeBps) external onlyOwner {
        _loanFeeBps = loanFeeBps;
        emit LoanFeeBpsSet(loanFeeBps);
    }

    /**
     * @notice Sets the minimum allowed loan duration
     * @dev This is only callable by the owner
     * @param minLoanDuration Minimum duration in seconds
     */
    function setMinLoanDuration(uint256 minLoanDuration) external onlyOwner {
        _minLoanDuration = minLoanDuration;
        emit MinLoanDurationSet(minLoanDuration);
    }

    /**
     * @notice Sets the maximum allowed loan duration
     * @dev This is only callable by the owner
     * @param maxLoanDuration Maximum duration in seconds
     */
    function setMaxLoanDuration(uint256 maxLoanDuration) external onlyOwner {
        _maxLoanDuration = maxLoanDuration;
        emit MaxLoanDurationSet(maxLoanDuration);
    }

    /**
     * @notice Sets the minimum allowed annual interest rate
     * @dev This is only callable by the owner
     * @param minInterestRateBps Minimum rate in basis points
     */
    function setMinInterestRate(uint256 minInterestRateBps) external onlyOwner {
        _minInterestRateBps = minInterestRateBps;
        emit MinInterestRateSet(minInterestRateBps);
    }

    /**
     * @notice Sets the maximum allowed annual interest rate
     * @dev This is only callable by the owner
     * @param maxInterestRateBps Maximum rate in basis points
     */
    function setMaxInterestRate(uint256 maxInterestRateBps) external onlyOwner {
        _maxInterestRateBps = maxInterestRateBps;
        emit MaxInterestRateSet(maxInterestRateBps);
    }

    /**
     * @notice Sets the treasury address that receives protocol fees
     * @dev This is only callable by the owner
     * @param treasuryAddress New treasury address (cannot be zero address)
     */
    function setTreasuryAddress(address treasuryAddress) external onlyOwner {
        if (treasuryAddress == address(0)) {
            revert InvalidTreasuryAddress(treasuryAddress);
        }
        _treasuryAddress = treasuryAddress;
        emit TreasuryAddressSet(treasuryAddress);
    }

    /**
     * @notice Sets the maximum number of operations allowed in batch functions
     * @dev This is only callable by the owner
     * @param batchLimit The new batch limit
     */
    function setBatchLimit(uint256 batchLimit) external onlyOwner {
        _batchLimit = batchLimit;
        emit BatchLimitSet(batchLimit);
    }

    /*////////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates a loan offer and stores it in the loanOffers mapping
     * @param nftCollection Address of the NFT collection
     * @param principal Loan amount in wrapped native tokens
     * @param interestRateBps Annual interest rate in basis points
     * @param loanDuration Loan duration in seconds
     * @param offerExpiry Timestamp when offer expires
     * @return offerId The ID of the created offer
     */
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

    /**
     * @notice Accepts a loan offer, transfers NFT to contract, and sends principal to borrower
     * @param offerId The ID of the offer to accept
     * @param tokenId The NFT token ID to use as collateral
     * @return loanId The ID of the created loan
     */
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

    /**
     * @notice Cancels a loan offer by setting it to inactive
     * @param offerId The ID of the offer to cancel
     */
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

    /**
     * @notice Repays a loan, returns NFT to borrower, and sends repayment to lender
     * @param loanId The ID of the loan to repay
     */
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

    /**
     * @notice Claims collateral NFT from a defaulted loan and transfers it to the lender
     * @param loanId The ID of the defaulted loan
     */
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

    /**
     * @notice Validates batch size is within allowed limits
     * @param batchSize Number of operations in the batch
     */
    function _validateBatchSize(uint256 batchSize) internal view {
        if (batchSize == 0) {
            revert BatchLengthCannotBeZero();
        }
        if (batchSize > _batchLimit) {
            revert BatchLimitExceeded(batchSize, _batchLimit);
        }
    }

    /**
     * @notice Calculates the protocol fee for a loan
     * @param principal The loan principal amount
     * @return The fee amount
     */
    function _calculateLoanFee(uint256 principal) internal view returns (uint256) {
        return (principal * _loanFeeBps) / 10000;
    }

    /**
     * @notice Calculates pro-rata interest based on actual loan duration
     * @param principal The loan principal amount
     * @param interestRateBps Annual interest rate in basis points
     * @param duration Actual duration of the loan in seconds
     * @return The interest amount
     */
    function _calculateInterest(uint256 principal, uint256 interestRateBps, uint256 duration)
        internal
        pure
        returns (uint256)
    {
        return (principal * interestRateBps * duration) / (10000 * 365 days);
    }

    /**
     * @notice Calculates the amount borrower receives after protocol fee deduction
     * @param principal The loan principal amount
     * @param fee The protocol fee amount
     * @return The amount after fee
     */
    function _calculateLoanAmountAfterFee(uint256 principal, uint256 fee) internal pure returns (uint256) {
        return principal - fee;
    }

    /**
     * @dev Calculates the total repayment amount (principal + interest)
     * @param principal The loan principal amount
     * @param interest The interest amount
     * @return The total repayment amount
     */
    function _calculateTotalRepayment(uint256 principal, uint256 interest) internal pure returns (uint256) {
        return principal + interest;
    }

    /*////////////////////////////////////////////////////////////////
                      EXTERNAL VIEW & PURE FUNCTIONS
    ////////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the treasury address
     * @return The treasury address
     */
    function getTreasuryAddress() external view returns (address) {
        return _treasuryAddress;
    }

    /**
     * @notice Gets the total number of loan offers created
     * @return The number of loan offers
     */
    function getLoanOfferCount() external view returns (uint256) {
        return _nextOfferId;
    }

    /**
     * @notice Gets the total number of loans created
     * @return The number of loans
     */
    function getLoanCount() external view returns (uint256) {
        return _nextLoanId;
    }

    /**
     * @notice Gets the details of a specific loan
     * @param loanId The ID of the loan
     * @return The Loan struct containing all loan details
     */
    function getLoanDetails(uint256 loanId) external view returns (Loan memory) {
        return loans[loanId];
    }

    /**
     * @notice Gets the details of a specific loan offer
     * @param offerId The ID of the loan offer
     * @return The LoanOffer struct containing all offer details
     */
    function getLoanOffer(uint256 offerId) external view returns (LoanOffer memory) {
        return loanOffers[offerId];
    }

    /**
     * @notice Checks if an NFT collection is whitelisted
     * @param collection Address of the NFT collection
     * @return True if whitelisted, false otherwise
     */
    function isCollectionWhitelisted(address collection) external view returns (bool) {
        return whitelistedCollections[collection];
    }

    /**
     * @notice Gets the current protocol fee in basis points
     * @return The fee in basis points
     */
    function getLoanFeeBps() external view returns (uint256) {
        return _loanFeeBps;
    }

    /**
     * @notice Gets the minimum allowed loan duration
     * @return The minimum duration in seconds
     */
    function getMinLoanDuration() external view returns (uint256) {
        return _minLoanDuration;
    }

    /**
     * @notice Gets the maximum allowed loan duration
     * @return The maximum duration in seconds
     */
    function getMaxLoanDuration() external view returns (uint256) {
        return _maxLoanDuration;
    }

    /**
     * @notice Gets the minimum allowed annual interest rate
     * @return The minimum rate in basis points
     */
    function getMinInterestRate() external view returns (uint256) {
        return _minInterestRateBps;
    }

    /**
     * @notice Gets the maximum allowed annual interest rate
     * @return The maximum rate in basis points
     */
    function getMaxInterestRate() external view returns (uint256) {
        return _maxInterestRateBps;
    }

    /**
     * @notice Gets the maximum batch size for batch operations
     * @return The batch limit
     */
    function getBatchLimit() external view returns (uint256) {
        return _batchLimit;
    }
}
