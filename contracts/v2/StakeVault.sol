// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

import { IStakeCustody } from "./interfaces/IStakeCustody.sol";
import { IModuleRegistry } from "./interfaces/IModuleRegistry.sol";
import { IV2Module } from "./interfaces/IV2Module.sol";
import { IV2Types } from "./interfaces/IV2Types.sol";
import { V2Errors } from "./libraries/V2Errors.sol";

/// @title StakeVault
/// @notice Canonical V2 custody module with typed locks, exact-balance accounting, and pull-based withdrawals.
/// @dev Every token in custody belongs to a named bucket: claimable, locked (by category), or protocol allocation.
///      Only registered canonical modules may mutate locks. User withdrawals cannot affect another account or claim.
///
///      ## Event completeness (V2-SC-132)
///
///      Every authoritative read cell is closed by at least one canonical event,
///      so a clean indexer reconstructs this module's read state by replaying the
///      ordered log stream alone. Cells, closing events, and the derivation rules
///      for aggregate cells are enumerated in
///      `V2EventCompleteness.catalogue()` and published on-chain by
///      `EventCompletenessAnchor`. No emission carries settlement, treasury, or
///      configuration authority: events are read-only evidence of state that the
///      contracts themselves already enforce.
contract StakeVault is ERC165, AccessControl, ReentrancyGuard, IStakeCustody {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    bytes32 public constant MODULE_SLASHING = keccak256("SLASHING");
    bytes32 public constant MODULE_SETTLEMENT = keccak256("SETTLEMENT");
    bytes32 public constant MODULE_VERIFICATION = keccak256("VERIFICATION");

    IModuleRegistry public immutable moduleRegistry;
    IERC20 public immutable stakingToken;

    mapping(address => bool) public supportedAssets;
    mapping(address => bool) public lockMutators;

    mapping(address => uint256) private _totalCustody;
    mapping(address => uint256) private _protocolAllocation;
    mapping(address => uint256) private _assetTotalLocked;
    mapping(address => uint256) private _assetTotalClaimable;
    mapping(address => mapping(address => uint256)) private _claimable;
    mapping(bytes32 => uint256) private _locks;

    mapping(uint256 => uint256) private _claimTotalVerifierStake;
    mapping(uint256 => mapping(address => uint256)) private _accountClaimVerifierStake;

    /// @notice Records the finalized settlement outcome per (claimId, round) to enforce idempotency.
    mapping(uint256 => mapping(uint256 => IV2Types.SettlementOutcome)) private _settlementOutcome;

    event VaultDeposited(address indexed asset, address indexed account, uint256 amount);
    event VaultLocked(
        address indexed asset,
        address indexed account,
        uint256 indexed claimId,
        uint256 round,
        IV2Types.LockCategory category,
        uint256 amount
    );
    event VaultUnlocked(
        address indexed asset,
        address indexed account,
        uint256 indexed claimId,
        uint256 round,
        IV2Types.LockCategory category,
        uint256 amount
    );
    event VaultWithdrawn(address indexed asset, address indexed account, uint256 amount);
    event ProtocolAllocationIncreased(address indexed asset, uint256 amount, bytes32 indexed reason);

    // -------------------------------------------------------------------------
    // V2-SC-132 event-completeness surface
    //
    // The four events below close the authoritative read cells that no
    // pre-existing emission carried. Each is emitted at the exact point of the
    // storage mutation it describes, in the same transaction and in canonical
    // log order, so a clean indexer that replays the ordered stream reconstructs
    // `supportedAssets`, `lockMutators`, per-cell locked principal after a
    // slash, and the protocol-allocation debit leg of a reward credit without
    // reading storage. No new authority, role, or settlement path is introduced.
    // -------------------------------------------------------------------------

    /// @notice Version tag carried by every canonical V2-SC-132 vault event.
    uint16 public constant EVENT_SCHEMA_VERSION = 1;

    /// @notice Emitted when an asset is enabled or disabled for custody.
    /// @dev Also emitted once at construction for the primary staking asset, so
    ///      a replay that starts at the deployment block never has to infer the
    ///      genesis supported-asset set.
    event SupportedAssetUpdated(
        address indexed asset, bool enabled, address indexed actor, uint64 timestamp, uint16 version
    );

    /// @notice Emitted when an address is granted or revoked lock-mutation authority.
    event LockMutatorUpdated(
        address indexed module, bool enabled, address indexed actor, uint64 timestamp, uint16 version
    );

    /// @notice Emitted when locked principal is moved into the protocol allocation.
    /// @dev Carries the full lock-cell coordinates. `ProtocolAllocationIncreased`
    ///      alone is not reconstructible: it names neither the debited lock cell
    ///      nor the actor that caused the slash.
    event VaultSlashed(
        address indexed asset,
        address indexed account,
        uint256 indexed claimId,
        uint256 round,
        IV2Types.LockCategory category,
        uint256 amount,
        bytes32 reason,
        uint64 timestamp,
        uint16 version
    );

    /// @notice Emitted when protocol allocation is debited to fund a reward credit.
    /// @dev Closes the allocation leg of `_creditReward`, which previously
    ///      mutated `_protocolAllocation` with no emission of its own.
    event ProtocolAllocationConsumed(
        address indexed asset, address indexed beneficiary, uint256 amount, uint64 timestamp, uint16 version
    );

    /// @param registry Canonical module registry used to authorize lock mutations.
    /// @param token Primary staking asset for the `IStakeCustody` surface.
    /// @param admin Governance or deployment authority.
    constructor(address registry, address token, address admin) {
        if (registry == address(0) || token == address(0) || admin == address(0)) revert V2Errors.ZeroAddress();

        moduleRegistry = IModuleRegistry(registry);
        stakingToken = IERC20(token);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);

        supportedAssets[token] = true;
        emit SupportedAssetUpdated(token, true, admin, uint64(block.timestamp), EVENT_SCHEMA_VERSION);
    }

    function protocolVersion() external pure override returns (uint16 major, uint16 minor) {
        return (2, 0);
    }

    function supportsInterface(bytes4 interfaceId) public view override(AccessControl, ERC165, IERC165) returns (bool) {
        return interfaceId == type(IStakeCustody).interfaceId || interfaceId == type(IV2Module).interfaceId
            || super.supportsInterface(interfaceId);
    }

    // -------------------------------------------------------------------------
    // IStakeCustody — verifier stake surface (primary asset, round 0)
    // -------------------------------------------------------------------------

    /// @inheritdoc IStakeCustody
    function depositStake(uint256 claimId, uint256 amount) external override nonReentrant {
        _assertSettlementNotFinalized(claimId, 0);
        address asset = address(stakingToken);
        address account = msg.sender;
        _deposit(account, asset, amount);
        _lock(asset, account, claimId, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL, amount);
        emit StakeDeposited(account, claimId, amount, uint64(block.timestamp), 1);
    }

    /// @inheritdoc IStakeCustody
    function releaseStake(uint256 claimId, address account, uint256 amount) external override nonReentrant {
        _onlyAuthorizedMutator();
        _assertSettlementNotFinalized(claimId, 0);
        address asset = address(stakingToken);
        _unlock(asset, account, claimId, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL, amount);
        emit StakeReleased(account, claimId, amount, uint64(block.timestamp), 1);
    }

    /// @inheritdoc IStakeCustody
    function slashStake(uint256 claimId, address account, uint256 amount, bytes32 reason)
        external
        override
        nonReentrant
    {
        _onlyAuthorizedMutator();
        _assertSettlementNotFinalized(claimId, 0);
        address asset = address(stakingToken);
        _slash(asset, account, claimId, 0, IV2Types.LockCategory.VERIFIER_PRINCIPAL, amount, reason);
        emit StakeSlashed(account, claimId, amount, reason, uint64(block.timestamp), 1);
    }

    /// @inheritdoc IStakeCustody
    function staked(uint256 claimId, address account) external view override returns (uint256) {
        return _accountClaimVerifierStake[claimId][account];
    }

    /// @inheritdoc IStakeCustody
    function totalStaked(uint256 claimId) external view override returns (uint256) {
        return _claimTotalVerifierStake[claimId];
    }

    // -------------------------------------------------------------------------
    // Extended multi-asset custody API
    // -------------------------------------------------------------------------

    /// @notice Deposits a supported asset into the caller's claimable balance.
    function deposit(address asset, uint256 amount) external nonReentrant {
        _deposit(msg.sender, asset, amount);
    }

    /// @notice Locks claimable balance into a typed lock cell. Authorized modules only.
    function lock(
        address asset,
        address account,
        uint256 claimId,
        uint256 round,
        IV2Types.LockCategory category,
        uint256 amount
    ) external nonReentrant {
        _onlyAuthorizedMutator();
        _assertSettlementNotFinalized(claimId, round);
        _lock(asset, account, claimId, round, category, amount);
        _creditStakeCell(asset, account, claimId, category, amount);
    }

    /// @notice Unlocks a typed lock cell back to claimable balance. Authorized modules only.
    function unlock(
        address asset,
        address account,
        uint256 claimId,
        uint256 round,
        IV2Types.LockCategory category,
        uint256 amount
    ) external nonReentrant {
        _onlyAuthorizedMutator();
        _assertSettlementNotFinalized(claimId, round);
        _unlock(asset, account, claimId, round, category, amount);
        _debitStakeCell(asset, account, claimId, category, amount);
    }

    /// @notice Moves locked principal into protocol allocation. Authorized modules only.
    function allocateLocked(
        address asset,
        address account,
        uint256 claimId,
        uint256 round,
        IV2Types.LockCategory category,
        uint256 amount,
        bytes32 reason
    ) external nonReentrant {
        _onlyAuthorizedMutator();
        _assertSettlementNotFinalized(claimId, round);
        _slash(asset, account, claimId, round, category, amount, reason);
    }

    // -------------------------------------------------------------------------
    // Typed settlement hooks (V2-SC-012)
    // -------------------------------------------------------------------------

    /// @inheritdoc IStakeCustody
    function settleConclusive(
        address asset,
        address account,
        uint256 claimId,
        uint256 round,
        uint256 principalAmount,
        uint256 rewardAmount
    ) external override nonReentrant {
        _onlySettlementModule();
        _assertSettlementNotFinalized(claimId, round);
        _settlementOutcome[claimId][round] = IV2Types.SettlementOutcome.CONCLUDED;

        if (principalAmount > 0) {
            _unlock(asset, account, claimId, round, IV2Types.LockCategory.VERIFIER_PRINCIPAL, principalAmount);
            _debitStakeCell(asset, account, claimId, IV2Types.LockCategory.VERIFIER_PRINCIPAL, principalAmount);
        }
        if (rewardAmount > 0) {
            _creditReward(asset, account, rewardAmount);
        }
        emit VaultSettledConclusive(
            asset, account, claimId, round, principalAmount, rewardAmount, uint64(block.timestamp), 1
        );
    }

    /// @inheritdoc IStakeCustody
    function refundInconclusive(address asset, address account, uint256 claimId, uint256 round, uint256 amount)
        external
        override
        nonReentrant
    {
        _onlySettlementModule();
        _assertSettlementNotFinalized(claimId, round);
        _settlementOutcome[claimId][round] = IV2Types.SettlementOutcome.REFUNDED;

        _unlock(asset, account, claimId, round, IV2Types.LockCategory.VERIFIER_PRINCIPAL, amount);
        _debitStakeCell(asset, account, claimId, IV2Types.LockCategory.VERIFIER_PRINCIPAL, amount);
        emit VaultRefundedInconclusive(asset, account, claimId, round, amount, uint64(block.timestamp), 1);
    }

    /// @inheritdoc IStakeCustody
    function carryForwardAppeal(
        address asset,
        address account,
        uint256 claimId,
        uint256 fromRound,
        uint256 toRound,
        uint256 amount
    ) external override nonReentrant {
        _onlySettlementModule();
        _assertSettlementNotFinalized(claimId, fromRound);
        _settlementOutcome[claimId][fromRound] = IV2Types.SettlementOutcome.CARRIED_FORWARD;

        _moveLock(asset, account, claimId, fromRound, toRound, amount);
        emit VaultCarriedForward(asset, account, claimId, fromRound, toRound, amount, uint64(block.timestamp), 1);
    }

    /// @inheritdoc IStakeCustody
    function rolloverRound(
        address asset,
        address account,
        uint256 claimId,
        uint256 fromRound,
        uint256 toRound,
        uint256 amount
    ) external override nonReentrant {
        _onlySettlementModule();
        _assertSettlementNotFinalized(claimId, fromRound);
        _settlementOutcome[claimId][fromRound] = IV2Types.SettlementOutcome.ROLLED_OVER;

        _moveLock(asset, account, claimId, fromRound, toRound, amount);
        emit VaultRolledOver(asset, account, claimId, fromRound, toRound, amount, uint64(block.timestamp), 1);
    }

    /// @inheritdoc IStakeCustody
    function finalUnlock(address asset, address account, uint256 claimId, uint256 round, uint256 amount)
        external
        override
        nonReentrant
    {
        _onlySettlementModule();
        _assertSettlementNotFinalized(claimId, round);
        _settlementOutcome[claimId][round] = IV2Types.SettlementOutcome.UNLOCKED;

        _unlock(asset, account, claimId, round, IV2Types.LockCategory.VERIFIER_PRINCIPAL, amount);
        _debitStakeCell(asset, account, claimId, IV2Types.LockCategory.VERIFIER_PRINCIPAL, amount);
        emit VaultFinalUnlocked(asset, account, claimId, round, amount, uint64(block.timestamp), 1);
    }

    /// @inheritdoc IStakeCustody
    function settlementOutcome(uint256 claimId, uint256 round)
        external
        view
        override
        returns (IV2Types.SettlementOutcome)
    {
        return _settlementOutcome[claimId][round];
    }

    /// @notice Pull-based withdrawal of the caller's claimable balance.
    function withdraw(address asset, uint256 amount) external nonReentrant {
        _withdraw(msg.sender, asset, amount);
    }

    // -------------------------------------------------------------------------
    // Reconciliation views
    // -------------------------------------------------------------------------

    /// @notice Total accounted custody for an asset.
    function totalCustody(address asset) external view returns (uint256) {
        return _totalCustody[asset];
    }

    /// @notice Locked principal for a specific lock cell.
    function lockedPrincipal(
        address asset,
        address account,
        uint256 claimId,
        uint256 round,
        IV2Types.LockCategory category
    ) external view returns (uint256) {
        return _locks[_lockKey(asset, account, claimId, round, category)];
    }

    /// @notice Claimable (unlocked) balance for an account and asset.
    function claimableBalance(address asset, address account) external view returns (uint256) {
        return _claimable[asset][account];
    }

    /// @notice Protocol-owned allocation held in custody (e.g. slashed stake).
    function protocolAllocation(address asset) external view returns (uint256) {
        return _protocolAllocation[asset];
    }

    /// @notice Returns the canonical conservation equation terms for the asset.
    /// @dev The invariant is: actualBalance == custody == claimable + locked + protocolAllocation.
    function reconcile(address asset) external view returns (uint256 custody, uint256 obligations) {
        return _reconcile(asset);
    }

    /// @notice Returns the canonical conservation terms including the raw on-chain balance for debugging and invariant checks.
    function conservation(address asset)
        external
        view
        returns (uint256 custody, uint256 obligations, uint256 actualBalance)
    {
        custody = _totalCustody[asset];
        obligations = _protocolAllocation[asset] + _assetTotalLocked[asset] + _assetTotalClaimable[asset];
        actualBalance = IERC20(asset).balanceOf(address(this));
    }

    // -------------------------------------------------------------------------
    // Administration
    // -------------------------------------------------------------------------

    /// @notice Enables or disables an asset for custody operations.
    function setSupportedAsset(address asset, bool enabled) external onlyRole(ADMIN_ROLE) {
        if (asset == address(0)) revert V2Errors.ZeroAddress();
        supportedAssets[asset] = enabled;
        emit SupportedAssetUpdated(asset, enabled, msg.sender, uint64(block.timestamp), EVENT_SCHEMA_VERSION);
    }

    /// @notice Grants or revokes explicit lock-mutation authority (governance override).
    function setLockMutator(address module, bool enabled) external onlyRole(ADMIN_ROLE) {
        if (module == address(0)) revert V2Errors.ZeroAddress();
        lockMutators[module] = enabled;
        emit LockMutatorUpdated(module, enabled, msg.sender, uint64(block.timestamp), EVENT_SCHEMA_VERSION);
    }

    /// @notice Returns whether an address may mutate locks.
    function isAuthorizedMutator(address caller) public view returns (bool) {
        if (lockMutators[caller]) return true;
        return _isRegisteredModule(caller, MODULE_SLASHING) || _isRegisteredModule(caller, MODULE_SETTLEMENT)
            || _isRegisteredModule(caller, MODULE_VERIFICATION);
    }

    // -------------------------------------------------------------------------
    // Internal accounting
    // -------------------------------------------------------------------------

    function _deposit(address account, address asset, uint256 amount) internal {
        if (amount == 0) revert V2Errors.ZeroAmount();
        if (!supportedAssets[asset]) revert V2Errors.UnsupportedAsset(asset);

        uint256 received = _transferIn(asset, account, amount);
        _claimable[asset][account] += received;
        _assetTotalClaimable[asset] += received;
        _totalCustody[asset] += received;

        _assertReconciliation(asset);
        emit VaultDeposited(asset, account, received);
    }

    function _lock(
        address asset,
        address account,
        uint256 claimId,
        uint256 round,
        IV2Types.LockCategory category,
        uint256 amount
    ) internal {
        if (amount == 0) revert V2Errors.ZeroAmount();
        if (category == IV2Types.LockCategory.NONE) revert V2Errors.ZeroAmount();

        uint256 available = _claimable[asset][account];
        if (available < amount) revert V2Errors.InsufficientClaimable(account, amount, available);

        _claimable[asset][account] = available - amount;
        _assetTotalClaimable[asset] -= amount;

        bytes32 key = _lockKey(asset, account, claimId, round, category);
        _locks[key] += amount;
        _assetTotalLocked[asset] += amount;

        if (category == IV2Types.LockCategory.VERIFIER_PRINCIPAL && asset == address(stakingToken)) {
            _accountClaimVerifierStake[claimId][account] += amount;
            _claimTotalVerifierStake[claimId] += amount;
        }

        _assertReconciliation(asset);
        emit VaultLocked(asset, account, claimId, round, category, amount);
    }

    function _unlock(
        address asset,
        address account,
        uint256 claimId,
        uint256 round,
        IV2Types.LockCategory category,
        uint256 amount
    ) internal {
        if (amount == 0) revert V2Errors.ZeroAmount();

        bytes32 key = _lockKey(asset, account, claimId, round, category);
        uint256 locked = _locks[key];
        if (locked < amount) revert V2Errors.InsufficientLocked(amount, locked);

        _locks[key] = locked - amount;
        _assetTotalLocked[asset] -= amount;
        _claimable[asset][account] += amount;
        _assetTotalClaimable[asset] += amount;

        if (category == IV2Types.LockCategory.VERIFIER_PRINCIPAL && asset == address(stakingToken)) {
            _accountClaimVerifierStake[claimId][account] -= amount;
            _claimTotalVerifierStake[claimId] -= amount;
        }

        _assertReconciliation(asset);
        emit VaultUnlocked(asset, account, claimId, round, category, amount);
    }

    function _slash(
        address asset,
        address account,
        uint256 claimId,
        uint256 round,
        IV2Types.LockCategory category,
        uint256 amount,
        bytes32 reason
    ) internal {
        if (amount == 0) revert V2Errors.ZeroAmount();

        bytes32 key = _lockKey(asset, account, claimId, round, category);
        uint256 locked = _locks[key];
        if (locked < amount) revert V2Errors.InsufficientLocked(amount, locked);

        _locks[key] = locked - amount;
        _assetTotalLocked[asset] -= amount;
        _protocolAllocation[asset] += amount;

        if (category == IV2Types.LockCategory.VERIFIER_PRINCIPAL && asset == address(stakingToken)) {
            _accountClaimVerifierStake[claimId][account] -= amount;
            _claimTotalVerifierStake[claimId] -= amount;
        }

        _assertReconciliation(asset);
        emit VaultSlashed(
            asset, account, claimId, round, category, amount, reason, uint64(block.timestamp), EVENT_SCHEMA_VERSION
        );
        emit ProtocolAllocationIncreased(asset, amount, reason);
    }

    /// @notice Credits the round-less verifier-stake cell and publishes the delta.
    /// @dev `IStakeCustody.staked(claimId, account)` is authoritative but carries
    ///      no round, so it is closed by the family-6 surface rather than by the
    ///      per-round lock family. `_lock` writes that cell for any staking-token
    ///      `VERIFIER_PRINCIPAL` lock, including the ones reached through the
    ///      generic `lock` hook, so the generic hook must publish the delta too:
    ///      otherwise a log-only indexer over-reports stake for a stake deposit
    ///      it never saw (V2-SC-132).
    function _creditStakeCell(
        address asset,
        address account,
        uint256 claimId,
        IV2Types.LockCategory category,
        uint256 amount
    ) internal {
        if (amount == 0 || category != IV2Types.LockCategory.VERIFIER_PRINCIPAL || asset != address(stakingToken)) return;
        emit StakeDeposited(account, claimId, amount, uint64(block.timestamp), EVENT_SCHEMA_VERSION);
    }

    /// @notice Debits the round-less verifier-stake cell and publishes the delta.
    /// @dev The debit counterpart of `_creditStakeCell`. Every path that unlocks
    ///      staking-token principal outside the family-6 surface — the generic
    ///      `unlock` hook, conclusive settlement, an inconclusive refund, and a
    ///      final unlock — must emit `StakeReleased`, so the stake cell stays
    ///      closed when settlement returns principal to the claimable balance.
    function _debitStakeCell(
        address asset,
        address account,
        uint256 claimId,
        IV2Types.LockCategory category,
        uint256 amount
    ) internal {
        if (amount == 0 || category != IV2Types.LockCategory.VERIFIER_PRINCIPAL || asset != address(stakingToken)) return;
        emit StakeReleased(account, claimId, amount, uint64(block.timestamp), EVENT_SCHEMA_VERSION);
    }

    function _withdraw(address account, address asset, uint256 amount) internal {
        if (amount == 0) revert V2Errors.ZeroAmount();

        uint256 available = _claimable[asset][account];
        if (available < amount) revert V2Errors.InsufficientClaimable(account, amount, available);

        _claimable[asset][account] = available - amount;
        _assetTotalClaimable[asset] -= amount;
        _totalCustody[asset] -= amount;

        IERC20(asset).safeTransfer(account, amount);

        _assertReconciliation(asset);
        emit VaultWithdrawn(asset, account, amount);
    }

    function _transferIn(address asset, address from, uint256 amount) internal returns (uint256 received) {
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(from, address(this), amount);
        received = IERC20(asset).balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert V2Errors.TransferAmountMismatch(amount, received);
    }

    function _lockKey(address asset, address account, uint256 claimId, uint256 round, IV2Types.LockCategory category)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(asset, account, claimId, round, category));
    }

    function _onlyAuthorizedMutator() internal view {
        if (!isAuthorizedMutator(msg.sender)) revert V2Errors.UnauthorizedModule(msg.sender);
    }

    function _isRegisteredModule(address caller, bytes32 moduleId) internal view returns (bool) {
        if (!moduleRegistry.isRegistered(moduleId)) return false;
        (address implementation,,) = moduleRegistry.module(moduleId);
        return implementation == caller;
    }

    /// @notice Restricts a hook to the registered SETTLEMENT module.
    function _onlySettlementModule() internal view {
        if (!_isRegisteredModule(msg.sender, MODULE_SETTLEMENT)) revert V2Errors.UnauthorizedModule(msg.sender);
    }

    /// @notice Reverts if a settlement outcome has already been recorded for the claim-round.
    function _assertSettlementNotFinalized(uint256 claimId, uint256 round) internal view {
        if (_settlementOutcome[claimId][round] != IV2Types.SettlementOutcome.NONE) {
            revert V2Errors.SettlementAlreadyFinalized(claimId, round);
        }
    }

    /// @notice Credits a reward to an account's claimable balance, funded from protocol allocation.
    function _creditReward(address asset, address account, uint256 amount) internal {
        if (amount == 0) revert V2Errors.ZeroAmount();
        uint256 allocation = _protocolAllocation[asset];
        if (allocation < amount) revert V2Errors.InsufficientProtocolAllocation(amount, allocation);

        _protocolAllocation[asset] = allocation - amount;
        _claimable[asset][account] += amount;
        _assetTotalClaimable[asset] += amount;

        _assertReconciliation(asset);
        emit ProtocolAllocationConsumed(asset, account, amount, uint64(block.timestamp), EVENT_SCHEMA_VERSION);
    }

    /// @notice Moves a VERIFIER_PRINCIPAL lock from one round to another without changing custody totals.
    function _moveLock(
        address asset,
        address account,
        uint256 claimId,
        uint256 fromRound,
        uint256 toRound,
        uint256 amount
    ) internal {
        if (amount == 0) revert V2Errors.ZeroAmount();
        if (fromRound == toRound) revert V2Errors.InvalidArgument("same round");

        bytes32 fromKey = _lockKey(asset, account, claimId, fromRound, IV2Types.LockCategory.VERIFIER_PRINCIPAL);
        uint256 locked = _locks[fromKey];
        if (locked < amount) revert V2Errors.InsufficientLocked(amount, locked);

        _locks[fromKey] = locked - amount;

        bytes32 toKey = _lockKey(asset, account, claimId, toRound, IV2Types.LockCategory.VERIFIER_PRINCIPAL);
        _locks[toKey] += amount;

        _assertReconciliation(asset);
    }

    function _assertReconciliation(address asset) internal view {
        (uint256 custody, uint256 obligations) = _reconcile(asset);
        uint256 actualBalance = IERC20(asset).balanceOf(address(this));

        if (obligations > custody) revert V2Errors.ObligationsExceedCustody(asset, custody, obligations);
        if (custody != obligations || actualBalance != custody) {
            revert V2Errors.ConservationInvariantViolation(asset, custody, obligations, actualBalance);
        }
    }

    function _reconcile(address asset) internal view returns (uint256 custody, uint256 obligations) {
        custody = _totalCustody[asset];
        obligations = _protocolAllocation[asset] + _assetTotalLocked[asset] + _assetTotalClaimable[asset];
    }
}
