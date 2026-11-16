// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 INHERITFI ( https://inheritfi.com / inheritfi.eth ). All rights reserved.
pragma solidity 0.8.38;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./InheritfiV1Types.sol";
import "./InheritfiV1InheritanceLib.sol";
import "./InheritfiV1GovernanceLib.sol";

/**
 * @title INHERITFI V1 Base
 * @notice Abstract base with all shared logic for INHERITFI V1 contracts.
 * @author INHERITFI ( https://inheritfi.com / inheritfi.eth )
 *
 * Heavy logic is extracted into InheritfiV1InheritanceLib and InheritfiV1GovernanceLib (external
 * libraries called via DELEGATECALL) to keep deployed bytecode below the
 * EIP-170 / EIP-3860 limits.
 */
abstract contract InheritfiV1Base is ERC20, Ownable2Step, ReentrancyGuard {

    // ============ Constants ============

    uint256 internal constant BP           = 10_000;
    uint256 internal constant MAX_TAX      = 30;
    uint256 private  constant MIN_P        = 3 days;
    uint256 private  constant MAX_P        = 90 days;
    uint256 private  constant MAX_INAC     = 180 days;
    uint256 private  constant MIN_REC_INAC = 14 days;
    uint256 private  constant MIN_INH_INAC = 21 days;
    uint256 private  constant MIN_REC_P    = 2 days;
    uint256 private  constant MIN_REX_P    = 7 days;
    uint256 private  constant MIN_CREC_P   = 3 days;
    uint256 private  constant MIN_TAX_P    = 3 days;
    uint256 private  constant MIN_RNO_P    = 90 days;
    uint256 private  constant MAX_RNO_P    = 180 days;
    uint256 private  constant MIN_Q_P      = 90 days;
    uint256 private  constant MAX_Q_P      = 180 days;
    uint256 private  constant MIN_QR_P     = 30 days;
    uint256 private  constant MAX_QR_P     = 180 days;
    uint256 private  constant MIN_DI_P     = 7 days;
    uint256 private  constant MAX_DI_P     = 90 days;
    uint256 private  constant MIN_OI_P     = 7 days;
    uint256 private  constant MAX_OI_P     = 90 days;

    // ============ Tax State ============

    uint256 public wrappingTax;
    uint256 public unwrappingTax;
    uint256 public inheritanceTax;
    uint256 public recoveryTax;

    // ============ Time Period State ============

    uint256 public recoveryInactivityPeriod         = 30 days;
    uint256 public inheritInactivityPeriod          = 45 days;
    uint256 public inheritWaitingTime               = 7  days;
    uint256 public inheritRemainingWaitingTime      = 14 days;
    uint256 public recoveryWaitingTime              = 7  days;
    uint256 public recoveryExecutionWindow          = 30 days;
    uint256 public contractRecoveryStartWaitingTime = 30 days;
    uint256 public contractRecoveryWaitingTime      = 30 days;
    uint256 public taxCollectionWaitingTime         = 7  days;
    uint256 public renounceOwnershipWaitingTime     = 90 days;
    uint256 public quorumInactivityPeriod           = 90 days;
    uint256 public quorumRollcallWindow             = 90 days;
    uint256 public delegateInvitationWindow         = 30 days;
    uint256 public ownerInvitationWindow            = 30 days;

    // ============ Limit State ============

    uint256 public maxHeirs         = 30;
    uint256 public maxRecoveryUsers = 15;
    uint256 public maxTreasuries    = 25;
    uint256 public maxDelegates     = 20;

    // ============ Treasury State ============

    Treasury[] public treasuries;
    mapping(address => bool) internal treasuryWallet;
    uint256 public treasuryTimestamp;
    uint256 public accumulatedTax;

    // ============ Delegate / Election State ============

    mapping(address => Delegate) public delegates;
    address[] public delegateList;

    mapping(address => OwnerCandidateRecord) public ownerCandidates;
    address[] public ownerCandidateList;
    mapping(address => bool) public pendingNomination;
    address[] public pendingNominationList;
    bool    public ownerElected;
    address public ownerElect;

    bool    public startContractRecovery;
    uint256 public startContractRecoveryTimestamp;

    bool    public startRenounceOwnership;
    uint256 public startRenounceOwnershipTimestamp;

    uint256 public lastOwnerActivityTimestamp;
    uint256 public ownerInvitationTimestamp;
    uint256 public ownershipEpoch;

    // ============ Owner-Election Lack-of-Quorum State ============
    // Rescue path when too few delegates remain to reach ELEC_THRESH (51).
    // See InheritfiV1GovernanceLib.
    bool    public quorumCallActive;
    uint256 public quorumCallTimestamp;
    address public quorumCallInitiator;
    mapping(address => bool) public presentConfirmed;
    address[] public presentList;

    // ============ User Data ============

    mapping(address => UserData) internal userData;

    // ============ Events ============

    event Wrapped(address indexed user, uint256 inAmt, uint256 outAmt, uint256 tax);
    event Unwrapped(address indexed user, uint256 inAmt, uint256 outAmt, uint256 tax);
    event HeirsUpdated(address indexed testator, uint256 count);
    event RecoveryUsersUpdated(address indexed testator, uint256 count);
    event InheritanceStarted(address indexed testator, address indexed initiator, uint256 ts);
    event InheritanceExecuted(address indexed testator, address indexed heir, uint256 amount, uint256 tax);
    event InheritanceRemainingExecuted(address indexed testator, address indexed heir, uint256 amount, uint256 tax);
    event RecoveryStarted(address indexed testator, address indexed initiator, uint256 ts);
    event RecoveryExecuted(address indexed testator, address indexed ru, uint256 amount, uint256 tax);
    event ActivityChecked(address indexed user, uint256 ts);
    event TaxRateUpdated(string name, uint256 oldRate, uint256 newRate);
    event TreasuryUpdated(uint256 ts);
    event TaxCollected(uint256 amount, uint256 ts);
    event DelegateAdded(address indexed d, uint256 wv, uint256 ts);
    event DelegateRemoved(address indexed d, uint256 ts);
    event DelegateAccepted(address indexed d, uint256 ts);
    event DelegateWeightUpdated(address indexed d, uint256 oldW, uint256 newW);
    event OwnerCandidateNominated(address indexed c, address indexed n, uint256 ts);
    event OwnerCandidateAccepted(address indexed c, uint256 ts);
    event OwnerCandidateVoted(address indexed c, address indexed v, uint256 votes, uint256 total);
    event OwnerCandidateCancelled(address indexed c, address indexed n, uint256 ts);
    event OwnerElectChosen(address indexed elect, uint256 votes, uint256 ts);
    event ContractRecoveryStarted(address indexed initiator, uint256 ts);
    event ContractRecoveryExecuted(address indexed newOwner, uint256 ts);
    event OwnerActivityChecked(uint256 ts);
    event QuorumCallInitiated(address indexed initiator, uint256 ts);
    event PresentConfirmed(address indexed delegate, uint256 ts);
    event QuorumCallCancelled(uint256 ts);
    event OwnerQuorateExecuted(uint256 presentCount, uint256 ts);
    event EmergencySingleOwnerElect(address indexed newOwner, uint256 ts);
    event TreasuryPendingChange(address indexed t, address indexed newW);
    event TreasuryChangeAccepted(address indexed old, address indexed newW);
    event TreasuryChangeCancelled(address indexed t);
    event MaxHeirsUpdated(uint256 old, uint256 nv);
    event MaxRecoveryUsersUpdated(uint256 old, uint256 nv);
    event MaxTreasuriesUpdated(uint256 old, uint256 nv);
    event MaxDelegatesUpdated(uint256 old, uint256 nv);
    event RecoveryInactivityPeriodUpdated(uint256 old, uint256 nv);
    event InheritInactivityPeriodUpdated(uint256 old, uint256 nv);
    event QuorumInactivityPeriodUpdated(uint256 old, uint256 nv);
    event QuorumRollcallWindowUpdated(uint256 old, uint256 nv);
    event DelegateInvitationWindowUpdated(uint256 old, uint256 nv);
    event OwnerInvitationWindowUpdated(uint256 old, uint256 nv);
    event InheritWaitingTimeUpdated(uint256 old, uint256 nv);
    event InheritRemainingWaitingTimeUpdated(uint256 old, uint256 nv);
    event RecoveryWaitingTimeUpdated(uint256 old, uint256 nv);
    event RecoveryExecutionWindowUpdated(uint256 old, uint256 nv);
    event ContractRecoveryStartWaitingTimeUpdated(uint256 old, uint256 nv);
    event ContractRecoveryWaitingTimeUpdated(uint256 old, uint256 nv);
    event TaxCollectionWaitingTimeUpdated(uint256 old, uint256 nv);
    event RenounceOwnershipWaitingTimeUpdated(uint256 old, uint256 nv);
    event RenounceOwnershipStarted(uint256 ts, uint256 executableAt);
    event RenounceOwnershipCancelled(uint256 ts);
    event EmergencyRecovery(address indexed token, address indexed to, uint256 amount, string tokenType);

    // ============ Modifiers ============

    modifier onlyTestator() {
        require(userData[msg.sender].activityTimestamp > 0 || balanceOf(msg.sender) > 0, "Not testator");
        _;
    }

    modifier onlyHeir(address testator) {
        require(userData[testator].heirIndex[msg.sender] > 0, "Not heir");
        _;
    }

    modifier onlyRecoveryUser(address testator) {
        require(userData[testator].isRecoveryUser[msg.sender], "Not recovery user");
        _;
    }

    modifier onlyDelegate() {
        require(delegates[msg.sender].isActive, "Not delegate");
        _;
    }

    modifier onlyTreasuryOrOwner() {
        require(_isTreasuryWallet(msg.sender) || msg.sender == owner(), "Not authorized");
        _;
    }

    /**
     * @notice onlyOwner plus proof of life: records the call as owner
     *         activity and disarms any delegate-initiated process.
     * @dev Replaces onlyOwner on every owner-gated function. See _ownerAlive().
     */
    modifier onlyOwnerAlive() {
        _checkOwner();
        _ownerAlive();
        _;
    }

    // ============ Internal Helpers ============

    function _isTreasuryWallet(address account) internal view returns (bool) {
        return treasuryWallet[account];
    }

    function _initBase() internal {
        wrappingTax    = 30;
        unwrappingTax  = 30;
        inheritanceTax = 30;
        recoveryTax    = 30;
        treasuryTimestamp  = block.timestamp;
        lastOwnerActivityTimestamp = block.timestamp;
    }

    function _taxSplit(uint256 amount, uint256 rate) internal pure returns (uint256 tax, uint256 net) {
        tax = (amount * rate) / BP;
        net = amount - tax;
    }

    /**
     * @dev Proof of life for msg.sender: refreshes the inactivity clock and,
     *      if an inheritance or recovery process is armed, disarms it via
     *      InheritfiV1InheritanceLib.checkActivity (DELEGATECALL keeps
     *      msg.sender). Deliberately parameterless: it can only ever act on
     *      the account that signed the transaction.
     */
    function _touch() internal {
        UserData storage d = userData[msg.sender];
        if (d.startInheritance || d.startRecovery) InheritfiV1InheritanceLib.checkActivity(userData);
        else d.activityTimestamp = block.timestamp;
    }

    // ============ ERC20 Overrides ============

    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount);
        userData[msg.sender].totalSent         += amount;
        _touch();
        userData[to].totalReceived += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(amount > 0 || msg.sender == from || allowance(from, msg.sender) > 0, "Not authorized");
        super.transferFrom(from, to, amount);
        userData[from].totalSent         += amount;
        if (msg.sender == from) _touch();
        userData[to].totalReceived += amount;
        return true;
    }

    // ============ Heir Management - delegates to InheritfiV1InheritanceLib ============

    function setHeirs(address[] memory wallets, uint256[] memory percentages) external onlyTestator {
        InheritfiV1InheritanceLib.setHeirs(
            userData,
            wallets,
            percentages,
            maxHeirs
        );
    }

    function getHeirs(address testator) external view returns (address[] memory wallets, uint256[] memory pcts) {
        UserData storage user = userData[testator];
        uint256 n = user.heirs.length;
        wallets = new address[](n);
        pcts    = new uint256[](n);
        for (uint256 i; i < n; i++) {
            wallets[i] = user.heirs[i].wallet;
            pcts[i]    = user.heirs[i].percentage;
        }
    }

    // ============ Recovery User Management - delegates to InheritfiV1InheritanceLib ============

    function setRecoveryUsers(address[] calldata wallets) external onlyTestator {
        InheritfiV1InheritanceLib.setRecoveryUsers(userData, wallets, maxRecoveryUsers);
    }

    function getRecoveryUsers(address testator) external view returns (address[] memory) {
        return userData[testator].recoveryUsers;
    }

    // ============ Inheritance Process - delegates to InheritfiV1InheritanceLib ============

    function startInheritance(address testator) external onlyHeir(testator) {
        InheritfiV1InheritanceLib.startInheritance(
            userData,
            testator,
            msg.sender,
            balanceOf(testator),
            inheritInactivityPeriod,
            recoveryExecutionWindow
        );
        _touch();
    }

    function executeInheritance(address testator) external onlyHeir(testator) nonReentrant {
        (uint256 tax, uint256 net) = InheritfiV1InheritanceLib.executeInheritance(
            userData,
            testator,
            msg.sender,
            balanceOf(testator),
            inheritWaitingTime,
            inheritanceTax
        );
        accumulatedTax += tax;
        if (tax > 0) _transfer(testator, address(this), tax);
        _transfer(testator, msg.sender, net);
        _touch();
    }

    function executeInheritanceRemaining(address testator) external onlyHeir(testator) nonReentrant {
        (
            address[] memory recipients,
            uint256[] memory taxes,
            uint256[] memory nets
        ) = InheritfiV1InheritanceLib.executeInheritanceRemaining(
            userData,
            testator,
            balanceOf(testator),
            inheritWaitingTime,
            inheritRemainingWaitingTime,
            inheritanceTax
        );
        uint256 n = recipients.length;
        for (uint256 i; i < n; i++) {
            if (recipients[i] != address(0) && nets[i] > 0) {
                accumulatedTax += taxes[i];
                if (taxes[i] > 0) _transfer(testator, address(this), taxes[i]);
                _transfer(testator, recipients[i], nets[i]);
            }
        }
        _touch();
    }

    // ============ Recovery Process - delegates to InheritfiV1InheritanceLib ============

    function startRecovery(address testator) external onlyRecoveryUser(testator) {
        InheritfiV1InheritanceLib.startRecovery(
            userData,
            testator,
            msg.sender,
            recoveryInactivityPeriod
        );
        _touch();
    }

    function executeRecovery(address testator) external onlyRecoveryUser(testator) nonReentrant {
        (uint256 tax, uint256 net) = InheritfiV1InheritanceLib.executeRecovery(
            userData,
            testator,
            msg.sender,
            balanceOf(testator),
            recoveryWaitingTime,
            recoveryTax
        );
        accumulatedTax += tax;
        if (tax > 0) _transfer(testator, address(this), tax);
        _transfer(testator, msg.sender, net);
        _touch();
    }

    // ============ Activity Check - delegates to InheritfiV1InheritanceLib ============

    function checkActivity() external onlyTestator {
        InheritfiV1InheritanceLib.checkActivity(userData);
    }

    // ============ View Functions ============

    function getUserInfo(address user) external view returns (
        uint256 totalReceived, uint256 totalSent, uint256 totalRecoveryRelease,
        uint256 totalInheritanceRelease, uint256 totalInheritanceRemainingRelease,
        uint256 activityTimestamp, uint256 heirCount, uint256 recoveryUserCount,
        bool inheritanceStarted, uint256 inheritanceStartTimestamp,
        bool recoveryStarted, uint256 recoveryStartTimestamp,
        bool inheritanceClaimsClosed
    ) {
        UserData storage d = userData[user];
        return (
            d.totalReceived, d.totalSent, d.totalRecoveryRelease,
            d.totalInheritanceRelease, d.totalInheritanceRemainingRelease,
            d.activityTimestamp, d.heirs.length, d.recoveryUsers.length,
            d.startInheritance, d.startInheritanceTimestamp,
            d.startRecovery,    d.startRecoveryTimestamp,
            d.inheritanceClaimsClosed
        );
    }

    function isUserInactive(address testator) external view returns (bool) {
        return block.timestamp >= userData[testator].activityTimestamp + inheritInactivityPeriod;
    }

    function getHeirInheritanceInfo(address testator, address heir) external view returns (
        uint256 percentage, uint256 released, bool hasReceived, uint256 potential, uint256 potentialRemaining
    ) {
        UserData storage user = userData[testator];
        uint256 idx = user.heirIndex[heir];
        require(idx > 0, "Not heir");
        Heir storage h = user.heirs[idx - 1];
        (potential, potentialRemaining) = InheritfiV1InheritanceLib.heirPotentials(
            userData, testator, heir, balanceOf(testator),
            inheritWaitingTime, inheritRemainingWaitingTime, inheritanceTax
        );
        return (
            h.percentage,
            h.inheritanceReleased,
            user.heirReceivedInheritance[heir],
            potential,
            potentialRemaining
        );
    }

    function getRecoveryUserInfo(address testator, address ru) external view returns (
        bool isAuthorized, bool recoveryStarted, uint256 recoveryStartTimestamp,
        bool inactivityElapsed, uint256 currentBalance
    ) {
        UserData storage user = userData[testator];
        return (
            user.isRecoveryUser[ru],
            user.startRecovery,
            user.startRecoveryTimestamp,
            block.timestamp >= user.activityTimestamp + recoveryInactivityPeriod,
            balanceOf(testator)
        );
    }

    // ============ Period & Limit Setters ============

    function setRecoveryInactivityPeriod(uint256 p) external onlyOwnerAlive {
        require(p >= MIN_REC_INAC && p <= MAX_INAC, "Bad period");
        require(p < inheritInactivityPeriod, "Must be < inherit");
        emit RecoveryInactivityPeriodUpdated(recoveryInactivityPeriod, p);
        recoveryInactivityPeriod = p;
    }
    function setInheritInactivityPeriod(uint256 p) external onlyOwnerAlive {
        require(p >= MIN_INH_INAC && p <= MAX_INAC, "Bad period");
        require(p > recoveryInactivityPeriod, "Must be > recovery");
        emit InheritInactivityPeriodUpdated(inheritInactivityPeriod, p);
        inheritInactivityPeriod = p;
    }
    function setInheritWaitingTime(uint256 p) external onlyOwnerAlive {
        require(p >= MIN_P && p <= MAX_P, "Bad period");
        emit InheritWaitingTimeUpdated(inheritWaitingTime, p);
        inheritWaitingTime = p;
    }
    function setInheritRemainingWaitingTime(uint256 p) external onlyOwnerAlive {
        require(p >= MIN_P && p <= MAX_P, "Bad period");
        emit InheritRemainingWaitingTimeUpdated(inheritRemainingWaitingTime, p);
        inheritRemainingWaitingTime = p;
    }
    function setRecoveryWaitingTime(uint256 p) external onlyOwnerAlive {
        require(p >= MIN_REC_P && p <= MAX_P, "Bad period");
        require(p + MIN_P <= recoveryExecutionWindow, "Must be < window");
        emit RecoveryWaitingTimeUpdated(recoveryWaitingTime, p);
        recoveryWaitingTime = p;
    }
    function setRecoveryExecutionWindow(uint256 p) external onlyOwnerAlive {
        require(p >= MIN_REX_P && p <= MAX_P, "Bad period");
        require(p >= recoveryWaitingTime + MIN_P, "Must be > waiting");
        emit RecoveryExecutionWindowUpdated(recoveryExecutionWindow, p);
        recoveryExecutionWindow = p;
    }
    function setContractRecoveryStartWaitingTime(uint256 p) external onlyOwnerAlive {
        require(p >= MIN_CREC_P && p <= MAX_P, "Bad period");
        emit ContractRecoveryStartWaitingTimeUpdated(contractRecoveryStartWaitingTime, p);
        contractRecoveryStartWaitingTime = p;
    }
    function setContractRecoveryWaitingTime(uint256 p) external onlyOwnerAlive {
        require(p >= MIN_CREC_P && p <= MAX_P, "Bad period");
        emit ContractRecoveryWaitingTimeUpdated(contractRecoveryWaitingTime, p);
        contractRecoveryWaitingTime = p;
    }
    function setTaxCollectionWaitingTime(uint256 p) external onlyOwnerAlive {
        require(p >= MIN_TAX_P && p <= MAX_P, "Bad period");
        emit TaxCollectionWaitingTimeUpdated(taxCollectionWaitingTime, p);
        taxCollectionWaitingTime = p;
    }
    function setRenounceOwnershipWaitingTime(uint256 p) external onlyOwnerAlive {
        require(p >= MIN_RNO_P && p <= MAX_RNO_P, "Bad period");
        emit RenounceOwnershipWaitingTimeUpdated(renounceOwnershipWaitingTime, p);
        renounceOwnershipWaitingTime = p;
    }
    function setQuorumInactivityPeriod(uint256 p) external onlyOwnerAlive {
        require(p >= MIN_Q_P && p <= MAX_Q_P, "Bad period");
        emit QuorumInactivityPeriodUpdated(quorumInactivityPeriod, p);
        quorumInactivityPeriod = p;
    }
    function setQuorumRollcallWindow(uint256 p) external onlyOwnerAlive {
        require(p >= MIN_QR_P && p <= MAX_QR_P, "Bad period");
        emit QuorumRollcallWindowUpdated(quorumRollcallWindow, p);
        quorumRollcallWindow = p;
    }
    function setDelegateInvitationWindow(uint256 p) external onlyOwnerAlive {
        require(p >= MIN_DI_P && p <= MAX_DI_P, "Bad period");
        emit DelegateInvitationWindowUpdated(delegateInvitationWindow, p);
        delegateInvitationWindow = p;
    }
    function setOwnerInvitationWindow(uint256 p) external onlyOwnerAlive {
        require(p >= MIN_OI_P && p <= MAX_OI_P, "Bad period");
        emit OwnerInvitationWindowUpdated(ownerInvitationWindow, p);
        ownerInvitationWindow = p;
    }

    function setMaxHeirs(uint256 v) external onlyOwnerAlive {
        require(v > 0 && v <= 40, "Bad value");
        emit MaxHeirsUpdated(maxHeirs, v); maxHeirs = v;
    }
    function setMaxRecoveryUsers(uint256 v) external onlyOwnerAlive {
        require(v > 0 && v <= 50, "Bad value");
        emit MaxRecoveryUsersUpdated(maxRecoveryUsers, v); maxRecoveryUsers = v;
    }
    function setMaxTreasuries(uint256 v) external onlyOwnerAlive {
        require(v > 0 && v <= 40, "Bad value");
        emit MaxTreasuriesUpdated(maxTreasuries, v); maxTreasuries = v;
    }
    function setMaxDelegates(uint256 v) external onlyOwnerAlive {
        require(v > 0 && v <= 50, "Bad value");
        emit MaxDelegatesUpdated(maxDelegates, v); maxDelegates = v;
    }

    // ============ Tax Setters ============

    function setWrappingTax(uint256 r) external onlyOwnerAlive {
        require(r <= MAX_TAX, "Rate too high");
        emit TaxRateUpdated("wrappingTax", wrappingTax, r); wrappingTax = r;
    }
    function setUnwrappingTax(uint256 r) external onlyOwnerAlive {
        require(r <= MAX_TAX, "Rate too high");
        emit TaxRateUpdated("unwrappingTax", unwrappingTax, r); unwrappingTax = r;
    }
    function setInheritanceTax(uint256 r) external onlyOwnerAlive {
        require(r <= MAX_TAX, "Rate too high");
        emit TaxRateUpdated("inheritanceTax", inheritanceTax, r); inheritanceTax = r;
    }
    function setRecoveryTax(uint256 r) external onlyOwnerAlive {
        require(r <= MAX_TAX, "Rate too high");
        emit TaxRateUpdated("recoveryTax", recoveryTax, r); recoveryTax = r;
    }

    // ============ Treasury Management - delegates to InheritfiV1GovernanceLib ============

    function setTreasuries(address[] calldata wallets, uint256[] calldata percentages) external onlyOwnerAlive {
        treasuryTimestamp = InheritfiV1GovernanceLib.setTreasuries(
            treasuries,
            treasuryWallet,
            wallets,
            percentages,
            maxTreasuries
        );
    }

    function getTreasuries() external view returns (address[] memory wallets, uint256[] memory pcts) {
        uint256 n = treasuries.length;
        wallets = new address[](n);
        pcts    = new uint256[](n);
        for (uint256 i; i < n; i++) {
            wallets[i] = treasuries[i].wallet;
            pcts[i]    = treasuries[i].percentage;
        }
    }

    function proposeTreasuryWalletChange(address newWallet) external {
        InheritfiV1GovernanceLib.proposeTreasuryWalletChange(treasuries, treasuryWallet, newWallet);
    }

    function acceptTreasuryWalletChange() external {
        InheritfiV1GovernanceLib.acceptTreasuryWalletChange(treasuries, treasuryWallet, taxCollectionWaitingTime);
    }

    function cancelTreasuryWalletChange() external {
        InheritfiV1GovernanceLib.cancelTreasuryWalletChange(treasuries);
    }

    // ============ Tax Collection ============

    function collectTax() external onlyTreasuryOrOwner nonReentrant {
        require(block.timestamp >= treasuryTimestamp + taxCollectionWaitingTime, "Too soon");
        require(accumulatedTax > 0, "No tax");
        require(treasuries.length > 0, "No treasuries");
        uint256 total = accumulatedTax;
        accumulatedTax = 0;
        uint256 n = treasuries.length;
        uint256 dist;
        for (uint256 i; i < n; i++) {
            uint256 share = (i == n - 1) ? total - dist : (total * treasuries[i].percentage) / BP;
            dist += share;
            if (share > 0) _transfer(address(this), treasuries[i].wallet, share);
        }
        emit TaxCollected(total, block.timestamp);
    }

    /**
     * @notice iTokens held by this contract beyond accumulatedTax (sent to it by mistake).
     *         The owner can recover them with emergencyRecoverERC20(address(this), to, amount).
     */
    function getRecoverableITokens() public view returns (uint256) {
        return balanceOf(address(this)) - accumulatedTax;
    }

    // ============ Delegate Management - delegates to InheritfiV1GovernanceLib ============

    function addDelegate(address d, uint256 wv) external onlyOwnerAlive {
        InheritfiV1GovernanceLib.addDelegate(
            delegates,
            d, wv,
            owner(),
            maxDelegates,
            delegateList.length,
            delegateInvitationWindow,
            ownershipEpoch
        );
    }

    function acceptDelegate() external {
        InheritfiV1GovernanceLib.acceptDelegate(delegates, ownerCandidates, pendingNomination, delegateList, delegateInvitationWindow, maxDelegates, ownershipEpoch);
    }

    function setDelegateWeight(address d, uint256 newW) external onlyOwnerAlive {
        InheritfiV1GovernanceLib.setDelegateWeight(
            delegates,
            ownerCandidates,
            pendingNomination,
            delegateList,
            d, newW
        );
    }

    function removeDelegate(address d) external onlyOwnerAlive {
        InheritfiV1GovernanceLib.removeDelegate(
            delegates,
            ownerCandidates,
            pendingNomination,
            delegateList,
            d
        );
    }

    function getDelegates() external view returns (address[] memory) { return delegateList; }

    // ============ Owner Election - delegates to InheritfiV1GovernanceLib ============

    function nominateOwnerCandidate(address candidate) external onlyDelegate {
        InheritfiV1GovernanceLib.nominateOwnerCandidate(
            delegates,
            ownerCandidates,
            pendingNomination,
            pendingNominationList,
            candidate,
            ownerElected,
            startContractRecovery,
            lastOwnerActivityTimestamp,
            contractRecoveryStartWaitingTime,
            delegateInvitationWindow,
            ownershipEpoch
        );
    }

    function acceptOwnerCandidacy() external {
        InheritfiV1GovernanceLib.acceptOwnerCandidacy(
            delegates,
            ownerCandidates,
            pendingNomination,
            pendingNominationList,
            ownerCandidateList
        );
    }

    function voteForOwnerCandidate(address candidate) external onlyDelegate {
        bool elected = InheritfiV1GovernanceLib.voteForOwnerCandidate(
            delegates,
            ownerCandidates,
            pendingNomination,
            candidate,
            ownerElected
        );
        if (elected) {
            ownerElect   = candidate;
            ownerElected = true;
            _clearCandidates();
        }
    }

    function cancelOwnerCandidacy(address candidate) external onlyDelegate {
        InheritfiV1GovernanceLib.cancelOwnerCandidacy(
            delegates,
            ownerCandidates,
            pendingNomination,
            pendingNominationList,
            ownerCandidateList,
            delegateList,
            candidate
        );
    }

    function getOwnerCandidates() external view returns (address[] memory) { return ownerCandidateList; }

    // ============ Contract Recovery - delegates to InheritfiV1GovernanceLib ============

    function startContractRecoveryProcess() external onlyDelegate {
        startContractRecoveryTimestamp = InheritfiV1GovernanceLib.startContractRecoveryProcess(
            startContractRecovery,
            ownerElected,
            lastOwnerActivityTimestamp,
            contractRecoveryStartWaitingTime
        );
        startContractRecovery = true;
    }

    function executeContractRecovery() external onlyDelegate {
        address newOwner = InheritfiV1GovernanceLib.executeContractRecovery(
            startContractRecovery,
            ownerElected,
            startContractRecoveryTimestamp,
            contractRecoveryWaitingTime,
            ownerElect
        );
        startContractRecovery = false;
        ownerElected          = false;
        ownerElect            = address(0);
        _clearQuorumCall();
        _transferOwnership(newOwner);
        lastOwnerActivityTimestamp = block.timestamp;
    }

    // ============ Owner-Election Lack-of-Quorum - delegates to InheritfiV1GovernanceLib ============

    function quorumCall() external onlyDelegate {
        InheritfiV1GovernanceLib.initiateOwnerQuorumCall(
            delegates,
            presentConfirmed,
            presentList,
            quorumCallActive,
            ownerElected,
            startContractRecovery,
            lastOwnerActivityTimestamp,
            quorumInactivityPeriod,
            msg.sender
        );
        quorumCallActive    = true;
        quorumCallTimestamp = block.timestamp;
        quorumCallInitiator = msg.sender;
    }

    function present() external onlyDelegate {
        bool allPresent = InheritfiV1GovernanceLib.confirmOwnerPresent(
            delegates,
            presentConfirmed,
            presentList,
            quorumCallActive,
            quorumCallTimestamp,
            quorumRollcallWindow,
            delegateList.length,
            msg.sender
        );
        if (allPresent) _clearQuorumCall();
    }

    /**
     * @notice After the roll-call window closes, transfer ownership to the sole
     *         responder, or drop silent delegates and redistribute their
     *         weightedVoting among those who responded.
     * @dev Every candidacy and vote is reset together with the roster change, so
     *      only candidates nominated by present delegates can take part in the
     *      new election and no candidacy of a removed nominator can stall it.
     */
    function quorate() external onlyDelegate nonReentrant {
        // A normal election may have already succeeded while the quorum call
        // was open; if so, the rescue path must not short-circuit it.
        require(!ownerElected, "Already elected");
        require(block.timestamp >= lastOwnerActivityTimestamp + quorumInactivityPeriod, "Owner active");
        // Reset first: no vote then needs retracting or re-tallying while the
        // roster changes, and _settleSoleSurvivorQuorum() still finds the
        // full delegateList.
        _clearCandidates();
        address soloSurvivor = InheritfiV1GovernanceLib.executeOwnerQuorate(
            delegates,
            ownerCandidates,
            pendingNomination,
            delegateList,
            presentConfirmed,
            presentList,
            quorumCallActive,
            quorumCallTimestamp,
            quorumRollcallWindow,
            msg.sender
        );

        if (soloSurvivor != address(0)) {
            _settleSoleSurvivorQuorum();
            startContractRecovery = false;
            ownerElected          = false;
            ownerElect            = address(0);
            _transferOwnership(soloSurvivor);
            lastOwnerActivityTimestamp = block.timestamp;
        } else {
            _clearQuorumCall();
        }
    }

    /**
     * @notice Live state of an open quorum roll-call.
     * @return active          Whether a roll-call is currently open.
     * @return initiator       Delegate that opened it, or address(0).
     * @return startedAt       When the roll-call was opened.
     * @return closesAt        When the roll-call window closes.
     * @return respondedCount  Delegates that have confirmed presence.
     * @return delegateCount   Active delegates on the roster.
     */
    function getQuorumCallInfo() external view returns (
        bool    active,
        address initiator,
        uint256 startedAt,
        uint256 closesAt,
        uint256 respondedCount,
        uint256 delegateCount
    ) {
        return (
            quorumCallActive,
            quorumCallInitiator,
            quorumCallTimestamp,
            quorumCallActive ? quorumCallTimestamp + quorumRollcallWindow : 0,
            presentList.length,
            delegateList.length
        );
    }

    function getPresentDelegates() external view returns (address[] memory) { return presentList; }

    // ============ Owner Activity Check ============

    function ownerCheck() external onlyOwner {
        _ownerAlive();
        startRenounceOwnership = false;
        emit OwnerActivityChecked(block.timestamp);
    }

    function transferOwnership(address newOwner) public override onlyOwnerAlive {
        require(!delegates[newOwner].isActive, "Is delegate");
        super.transferOwnership(newOwner);
        ownerInvitationTimestamp = block.timestamp;
    }

    function acceptOwnership() public override {
        require(block.timestamp <= ownerInvitationTimestamp + ownerInvitationWindow, "Invite expired");
        require(!delegates[msg.sender].isActive, "Is delegate");
        super.acceptOwnership();
        _ownerAlive();
    }

    function _transferOwnership(address newOwner) internal override {
        super._transferOwnership(newOwner);
        startRenounceOwnership          = false;
        startRenounceOwnershipTimestamp = 0;
        ownershipEpoch++;
    }

    // ============ Renounce Ownership ============

    function startRenounceOwnershipProcess() external onlyOwnerAlive {
        startRenounceOwnership          = true;
        startRenounceOwnershipTimestamp = block.timestamp;
        emit RenounceOwnershipStarted(block.timestamp, block.timestamp + renounceOwnershipWaitingTime);
    }

    /**
     * @notice Aborts an in-flight ownership renunciation.
     * @dev Like every owner action (onlyOwnerAlive), it is also a proof of
     *      life and clears any election, roll-call and nomination in progress.
     */
    function cancelRenounceOwnershipProcess() external onlyOwnerAlive {
        require(startRenounceOwnership, "Not started");
        startRenounceOwnership          = false;
        startRenounceOwnershipTimestamp = 0;
        emit RenounceOwnershipCancelled(block.timestamp);
    }

    function renounceOwnership() public override onlyOwner {
        require(startRenounceOwnership, "Not started");
        require(block.timestamp >= startRenounceOwnershipTimestamp + renounceOwnershipWaitingTime, "Too soon");
        super.renounceOwnership();
    }

    // ============ Emergency Recovery ============

    /// @dev Underlying asset of the wrapper (address(0) for native ETH). The ERC-721 and ERC-1155
    ///      recovery paths can never call it, nor this contract itself.
    function _underlyingAsset() internal view virtual returns (address);

    function emergencyRecoverERC721(address nft, address to, uint256 tokenId) external onlyOwnerAlive {
        require(to != address(0) && nft != address(0) && nft.code.length > 0, "Bad addr");
        require(nft != address(this) && nft != _underlyingAsset(), "Protected asset");
        (bool ok,) = nft.call(abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", address(this), to, tokenId));
        require(ok, "NFT transfer failed");
        emit EmergencyRecovery(nft, to, tokenId, "ERC721");
    }

    function emergencyRecoverERC1155(address token, address to, uint256 tokenId, uint256 amount) external onlyOwnerAlive {
        require(to != address(0) && token != address(0) && token.code.length > 0 && amount > 0, "Bad input");
        require(token != address(this) && token != _underlyingAsset(), "Protected asset");
        (bool ok,) = token.call(abi.encodeWithSignature("safeTransferFrom(address,address,uint256,uint256,bytes)", address(this), to, tokenId, amount, ""));
        require(ok, "ERC1155 transfer failed");
        emit EmergencyRecovery(token, to, amount, "ERC1155");
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }
    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    // ============ Private Election Helpers ============

    function _clearCandidates() internal {
        InheritfiV1GovernanceLib.clearCandidates(
            delegates,
            ownerCandidates,
            pendingNomination,
            pendingNominationList,
            ownerCandidateList,
            delegateList
        );
    }

    /// @dev Wipes every delegate and clears roll-call bookkeeping; used only by
    ///      quorate()'s sole-survivor path.
    function _settleSoleSurvivorQuorum() private {
        InheritfiV1GovernanceLib.settleSoloSurvivorQuorum(
            delegates, delegateList, presentConfirmed, presentList
        );
        quorumCallActive    = false;
        quorumCallTimestamp = 0;
        quorumCallInitiator = address(0);
    }

    function _clearQuorumCall() private {
        InheritfiV1GovernanceLib.clearQuorumCall(presentConfirmed, presentList);
        quorumCallActive    = false;
        quorumCallTimestamp = 0;
        quorumCallInitiator = address(0);
    }

    /**
     * @notice Records owner liveness and disarms every governance process
     *         that only exists because the owner appeared to be gone.
     * @dev Called by the onlyOwnerAlive modifier on every owner-gated
     *      function, so any signed owner action is proof of life. A
     *      process can only have been started after a full inactivity
     *      period, so cancelling it here is never accidental.
     */
    function _ownerAlive() internal {
        lastOwnerActivityTimestamp = block.timestamp;
        startContractRecovery = false;
        ownerElected          = false;
        ownerElect            = address(0);
        _clearCandidates();
        _clearQuorumCall();
    }
}
