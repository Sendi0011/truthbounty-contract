// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IEventCompleteness } from "../interfaces/IEventCompleteness.sol";

/// @title V2EventCompleteness
/// @notice Pure, authoritative enumeration of every canonical V2 read cell, the
///         canonical events that close it, and the events that merely restate
///         it (V2-SC-132).
/// @dev    Pure only: no state, no authority, no settlement or treasury
///         surface, and no call a consumer could use to mutate protocol state.
///         On-chain publishers and off-chain consumers derive identical cell
///         identities, closing sets, and catalogue roots from identical inputs,
///         so a mismatch is detectable as drift rather than as silent
///         under-reporting.
///
///         ## The completeness claim
///
///         The claim has exactly two halves, and both are mechanically checkable:
///
///         1. **Closure** — every cell listed here is closed by at least one
///            canonical event. `assertCatalogueComplete()` reverts otherwise, so
///            an incomplete catalogue can never be published.
///         2. **Exhaustion** — no authoritative read cell reachable through a
///            public read function of a canonical V2 module is absent from the
///            list. This half is a review obligation, discharged cell by cell in
///            `docs/v2/event-completeness-projection-replay.md` and pinned by
///            `catalogueRoot`, which changes if a cell is ever added without a
///            corresponding catalogue entry.
///
///         ## Closing events versus restatements
///
///         Several canonical V2 emissions describe the same state delta twice:
///         a primitive event and a summary event, or a cell-specific event and a
///         general one. Replay MUST NOT apply both — that double counts. The
///         catalogue therefore splits every cell's emissions into
///
///         - `closingEvents` — the canonical, mutually exclusive sources a
///           consumer applies; and
///         - `restatements` — emissions that re-describe the same delta and exist
///           only as cross-checks. Applying them is a projection bug, and
///           `assertCatalogueComplete()` proves the two sets are disjoint.
///
///         Example: `settleConclusive` emits both the primitive
///         `VaultUnlocked`/`ProtocolAllocationConsumed` pair and the summary
///         `VaultSettledConclusive`. Only the primitives close the claimable
///         cell; the summary is a restatement.
library V2EventCompleteness {
    // =========================================================================
    // Domain and bounds
    // =========================================================================

    /// @notice Domain separator for cell identities and catalogue roots.
    bytes32 internal constant CELL_DOMAIN = keccak256("TRUTHBOUNTY.V2.EVENT_COMPLETENESS.CELL.v1");

    /// @notice Enumeration version of the cell catalogue.
    uint16 internal constant COMPLETENESS_VERSION = 1;

    /// @notice Hard cap on enumerated cells. Bounded by a compile-time constant,
    ///         so no enumeration call can perform an unbounded loop.
    uint256 internal constant MAX_CELLS = 64;

    /// @notice Hard cap on enumerated modules.
    uint256 internal constant MAX_MODULES = 16;

    /// @notice Hard cap on cell/event bindings across the whole catalogue.
    uint256 internal constant MAX_BINDINGS = 256;

    /// @notice Hard cap on closing events bound to a single cell.
    uint256 internal constant MAX_CLOSING_EVENTS = 8;

    /// @notice Hard cap on restatements bound to a single cell.
    uint256 internal constant MAX_RESTATEMENTS = 8;

    /// @notice Hard cap on a single `cellCoverage` page.
    uint256 internal constant MAX_COVERAGE_PAGE_SIZE = 8;

    /// @notice Coverage ordinals, spelled out so the catalogue never depends on
    ///         enum declaration order at a call site.
    uint8 internal constant COVERAGE_DIRECT = 0;
    uint8 internal constant COVERAGE_AGGREGATE = 1;
    uint8 internal constant COVERAGE_DERIVED = 2;

    // =========================================================================
    // Canonical module ids
    // =========================================================================

    bytes32 internal constant MODULE_STAKE_CUSTODY = keccak256("STAKE_CUSTODY");
    bytes32 internal constant MODULE_EVIDENCE = keccak256("EVIDENCE");
    bytes32 internal constant MODULE_FINAL_REWARD_ALLOCATOR = keccak256("FINAL_REWARD_ALLOCATOR");
    bytes32 internal constant MODULE_AGGREGATION = keccak256("AGGREGATION");
    bytes32 internal constant MODULE_SIGNATURE_NONCES = keccak256("SIGNATURE_NONCES");
    bytes32 internal constant MODULE_EMERGENCY_GATEKEEPER = keccak256("EMERGENCY_GATEKEEPER");
    bytes32 internal constant MODULE_CONSUMER_GUARANTEES = keccak256("CONSUMER_GUARANTEES");
    bytes32 internal constant MODULE_EVENT_COMPLETENESS = keccak256("EVENT_COMPLETENESS");

    // =========================================================================
    // Cell indices (global enumeration order)
    // =========================================================================

    // StakeVault — cells 0..9
    uint256 internal constant CELL_VAULT_SUPPORTED_ASSET = 0;
    uint256 internal constant CELL_VAULT_LOCK_MUTATOR = 1;
    uint256 internal constant CELL_VAULT_CLAIMABLE = 2;
    uint256 internal constant CELL_VAULT_LOCKED_PRINCIPAL = 3;
    uint256 internal constant CELL_VAULT_TOTAL_CUSTODY = 4;
    uint256 internal constant CELL_VAULT_PROTOCOL_ALLOCATION = 5;
    uint256 internal constant CELL_VAULT_ASSET_TOTAL_CLAIMABLE = 6;
    uint256 internal constant CELL_VAULT_ASSET_TOTAL_LOCKED = 7;
    uint256 internal constant CELL_VAULT_VERIFIER_STAKE = 8;
    uint256 internal constant CELL_VAULT_SETTLEMENT_OUTCOME = 9;

    // EvidenceRegistry — cells 10..15
    uint256 internal constant CELL_EVIDENCE_COMMITMENT = 10;
    uint256 internal constant CELL_EVIDENCE_CLAIM_INDEX = 11;
    uint256 internal constant CELL_EVIDENCE_CONTRIBUTOR_NONCE = 12;
    uint256 internal constant CELL_EVIDENCE_COMMITMENT_EXISTS = 13;
    uint256 internal constant CELL_EVIDENCE_STATUS = 14;
    uint256 internal constant CELL_EVIDENCE_PAUSED = 15;

    // FinalRewardAllocator — cells 16..22
    uint256 internal constant CELL_ALLOCATOR_FUNDED = 16;
    uint256 internal constant CELL_ALLOCATOR_ALLOCATED = 17;
    uint256 internal constant CELL_ALLOCATOR_CLAIMABLE = 18;
    uint256 internal constant CELL_ALLOCATOR_SETTLEMENT_FUNDED = 19;
    uint256 internal constant CELL_ALLOCATOR_SETTLEMENT_ALLOCATED = 20;
    uint256 internal constant CELL_ALLOCATOR_FINALIZED = 21;
    uint256 internal constant CELL_ALLOCATOR_FINAL_OUTCOME = 22;

    // Aggregation — cell 23
    uint256 internal constant CELL_AGGREGATION_OUTCOME = 23;

    // SignatureNonces — cell 24
    uint256 internal constant CELL_NONCE_BITMAP = 24;

    // EmergencyGatekeeper — cells 25..29
    uint256 internal constant CELL_EMERGENCY_SCOPE_PAUSED = 25;
    uint256 internal constant CELL_EMERGENCY_SCOPE_MAX_LEVEL = 26;
    uint256 internal constant CELL_EMERGENCY_CONTROLLER = 27;
    uint256 internal constant CELL_EMERGENCY_REWIRE_DELAY = 28;
    uint256 internal constant CELL_EMERGENCY_LAST_REWIRE = 29;

    uint256 internal constant CELL_COUNT = 30;
    uint256 internal constant MODULE_COUNT = 8;

    // =========================================================================
    // Reduction rule identities
    //
    // A cell whose post-state is not a field copy of an event payload names the
    // reduction a consumer must apply. Publishing the rule id means a consumer
    // can prove it applied the intended reduction instead of an ad-hoc one.
    // =========================================================================

    /// @notice Aggregate cells are the sum of their per-key cells, accumulated in
    ///         canonical order.
    bytes32 internal constant RULE_SUM_OVER_PER_KEY = keccak256("R0:sum-over-per-key-cells");

    /// @notice The `Stake*` family is the canonical source of the verifier-stake
    ///         aggregate; `VaultLocked`/`VaultUnlocked`/`VaultSlashed` restate
    ///         the same delta when the asset is the staking token and the
    ///         category is `VERIFIER_PRINCIPAL`, and are cross-checks only.
    bytes32 internal constant RULE_STAKE_FAMILY_CANONICAL = keccak256("R6:stake-family-canonical-vault-locks-restate");

    /// @notice Contributor nonce is `max(observed nonce) + 1` over the ordered
    ///         `EvidenceCommitted` stream for that contributor.
    bytes32 internal constant RULE_CONTRIBUTOR_NONCE_MONOTONIC = keccak256("R1:contributor-nonce-monotonic");

    /// @notice The dedupe flag is set once a `EvidenceCommitted` log exists with
    ///         matching `(claimId, contributor, contentDigest, metadataDigest)`.
    bytes32 internal constant RULE_COMMITMENT_DEDUPE = keccak256("R2:commitment-dedupe");

    /// @notice The settlement outcome is the identity of the settlement event
    ///         that closed the `(claimId, round)` cell; `NONE` until one arrives.
    bytes32 internal constant RULE_SETTLEMENT_OUTCOME_FROM_EVENT = keccak256("R3:settlement-outcome-from-event");

    /// @notice The allocator's finalized flag is set once `RewardsFinalized` has
    ///         been observed for the settlement id.
    bytes32 internal constant RULE_FINALIZED_ON_FINALIZE = keccak256("R4:finalized-on-rewards-finalized");

    /// @notice The last-rewire timestamp is the block timestamp of the log that
    ///         last wrote the wired controller.
    bytes32 internal constant RULE_REWIRE_TIMESTAMP_FROM_BLOCK = keccak256("R5:rewire-timestamp-from-block");

    /// @notice An evidence record's status is `SUBMITTED` from its
    ///         `EvidenceCommitted` log until an `EvidenceStatusChanged` log
    ///         overwrites it, and the record is absent before the commitment.
    /// @dev The commitment log carries no status field, so publishing
    ///      `EvidenceStatusChanged` alone would leave a consumer unable to tell
    ///      a committed record in `SUBMITTED` from one whose status it never
    ///      observed at all.
    bytes32 internal constant RULE_EVIDENCE_STATUS_FROM_COMMITMENT =
        keccak256("R7:evidence-status-defaults-submitted-at-commit");

    // =========================================================================
    // Canonical event signatures
    // =========================================================================

    bytes32 private constant SIG_VAULT_DEPOSITED = keccak256("VaultDeposited(address,address,uint256)");
    bytes32 private constant SIG_VAULT_LOCKED = keccak256("VaultLocked(address,address,uint256,uint256,uint8,uint256)");
    bytes32 private constant SIG_VAULT_UNLOCKED =
        keccak256("VaultUnlocked(address,address,uint256,uint256,uint8,uint256)");
    bytes32 private constant SIG_VAULT_WITHDRAWN = keccak256("VaultWithdrawn(address,address,uint256)");
    bytes32 private constant SIG_PROTOCOL_ALLOCATION_INCREASED =
        keccak256("ProtocolAllocationIncreased(address,uint256,bytes32)");
    bytes32 private constant SIG_PROTOCOL_ALLOCATION_CONSUMED =
        keccak256("ProtocolAllocationConsumed(address,address,uint256,uint64,uint16)");
    bytes32 private constant SIG_SUPPORTED_ASSET_UPDATED =
        keccak256("SupportedAssetUpdated(address,bool,address,uint64,uint16)");
    bytes32 private constant SIG_LOCK_MUTATOR_UPDATED =
        keccak256("LockMutatorUpdated(address,bool,address,uint64,uint16)");
    bytes32 private constant SIG_VAULT_SLASHED =
        keccak256("VaultSlashed(address,address,uint256,uint256,uint8,uint256,bytes32,uint64,uint16)");
    bytes32 private constant SIG_STAKE_DEPOSITED = keccak256("StakeDeposited(address,uint256,uint256,uint64,uint16)");
    bytes32 private constant SIG_STAKE_RELEASED = keccak256("StakeReleased(address,uint256,uint256,uint64,uint16)");
    bytes32 private constant SIG_STAKE_SLASHED =
        keccak256("StakeSlashed(address,uint256,uint256,bytes32,uint64,uint16)");
    bytes32 private constant SIG_VAULT_SETTLED_CONCLUSIVE =
        keccak256("VaultSettledConclusive(address,address,uint256,uint256,uint256,uint256,uint64,uint16)");
    bytes32 private constant SIG_VAULT_REFUNDED_INCONCLUSIVE =
        keccak256("VaultRefundedInconclusive(address,address,uint256,uint256,uint256,uint64,uint16)");
    bytes32 private constant SIG_VAULT_CARRIED_FORWARD =
        keccak256("VaultCarriedForward(address,address,uint256,uint256,uint256,uint256,uint64,uint16)");
    bytes32 private constant SIG_VAULT_ROLLED_OVER =
        keccak256("VaultRolledOver(address,address,uint256,uint256,uint256,uint256,uint64,uint16)");
    bytes32 private constant SIG_VAULT_FINAL_UNLOCKED =
        keccak256("VaultFinalUnlocked(address,address,uint256,uint256,uint256,uint64,uint16)");
    bytes32 private constant SIG_EVIDENCE_COMMITTED =
        keccak256("EvidenceCommitted(uint256,uint256,address,bytes32,bytes32,uint256,uint64,uint16)");
    bytes32 private constant SIG_EVIDENCE_STATUS_CHANGED =
        keccak256("EvidenceStatusChanged(uint256,uint8,uint8,address,uint64,uint16)");
    bytes32 private constant SIG_EMERGENCY_PAUSE_ACTIVATED =
        keccak256("EmergencyPauseActivatedV1(address,bytes32,uint64,uint16)");
    bytes32 private constant SIG_EMERGENCY_PAUSE_RECOVERED =
        keccak256("EmergencyPauseRecoveredV1(address,uint64,uint16)");
    bytes32 private constant SIG_REWARD_POOL_FUNDED = keccak256("RewardPoolFunded(address,uint256,bytes32)");
    bytes32 private constant SIG_REWARDS_FINALIZED = keccak256("RewardsFinalized(bytes32,address,uint8,uint256)");
    bytes32 private constant SIG_REWARD_ALLOCATED = keccak256("RewardAllocated(bytes32,uint8,address,address,uint256)");
    bytes32 private constant SIG_REWARD_CLAIMED = keccak256("RewardClaimed(address,address,uint256)");
    bytes32 private constant SIG_AGGREGATION_FINALIZED =
        keccak256("AggregationFinalized(uint256,bool,uint256,uint256,uint64,uint16)");
    bytes32 private constant SIG_NONCE_CONSUMED = keccak256("NonceConsumed(address,uint256)");
    bytes32 private constant SIG_NONCE_CANCELLED = keccak256("NonceCancelled(address,uint256)");
    bytes32 private constant SIG_SCOPE_PAUSE_UPDATED = keccak256("ScopePauseUpdated(bytes32,address,bool)");
    bytes32 private constant SIG_EMERGENCY_PAUSED = keccak256("EmergencyPaused(bytes32,address,uint64,uint16)");
    bytes32 private constant SIG_EMERGENCY_UNPAUSED = keccak256("EmergencyUnpaused(bytes32,address,uint64,uint16)");
    bytes32 private constant SIG_SCOPE_MAX_PAUSE_LEVEL_SET = keccak256("ScopeMaxPauseLevelSet(bytes32,uint8)");
    bytes32 private constant SIG_EMERGENCY_CONTROLLER_REWIRED =
        keccak256("EmergencyControllerRewired(address,address,uint256)");
    bytes32 private constant SIG_EMERGENCY_REWIRE_DELAY_UPDATED =
        keccak256("EmergencyRewireDelayUpdated(uint256,uint256)");

    // =========================================================================
    // Errors (all library-owned; no contract state is read or written)
    // =========================================================================

    /// @notice A published record disagrees with the canonical catalogue.
    error InvalidRecord(string reason);
    /// @notice A cell has no canonical closing event, so replay cannot close it.
    error UncoveredCell(uint256 cellIndex);
    /// @notice A cell or module index is outside the canonical enumeration.
    error IndexOutOfRange(uint256 index);
    /// @notice A requested page size is outside the bounded range.
    error InvalidPageLimit(uint256 limit);
    /// @notice A closing-event or restatement set exceeds its bound.
    error OversizedEventSet(uint256 cellIndex);
    /// @notice An event is listed as both a closing source and a restatement of
    ///         the same cell, so replay could double count it.
    error AmbiguousCellEvent(uint256 cellIndex);
    /// @notice A cell's coverage class and reduction rule disagree.
    error IncoherentReductionRule(uint256 cellIndex);

    // =========================================================================
    // Cell descriptor
    // =========================================================================

    /// @dev One canonical read cell with its canonical sources, its
    ///      restatements, and the reduction a consumer must apply. Declared once,
    ///      in one place, so the catalogue cannot drift between accessors.
    struct CellDescriptor {
        bytes32 moduleId;
        uint8 coverage;
        bytes32 reductionRuleId;
        bytes32[] closingEvents;
        bytes32[] restatements;
    }

    // =========================================================================
    // Enumeration totals (bounded by compile-time constants)
    // =========================================================================

    /// @notice Total number of authoritative read cells in the canonical V2 protocol.
    function cellCount() internal pure returns (uint256) {
        return CELL_COUNT;
    }

    /// @notice Total number of canonical modules covered by the catalogue.
    function moduleCount() internal pure returns (uint256) {
        return MODULE_COUNT;
    }

    /// @notice Total number of cell/event bindings across all cells.
    /// @dev Restatements are not bindings: they are cross-checks, not sources.
    function bindingCount() internal pure returns (uint256 total) {
        uint256 count = CELL_COUNT;
        for (uint256 i; i < count;) {
            total += closingEventsOf(i).length;
            unchecked {
                ++i;
            }
        }
    }

    // =========================================================================
    // Cell accessors
    // =========================================================================

    /// @notice Stable identity of a cell, domain-separated from every other cell.
    function cellIdOf(uint256 cellIndex) internal pure returns (bytes32) {
        if (cellIndex >= CELL_COUNT) revert IndexOutOfRange(cellIndex);
        CellDescriptor memory d = _descriptor(cellIndex);
        return keccak256(abi.encode(CELL_DOMAIN, d.moduleId, cellIndex));
    }

    /// @notice Owning module id of a cell.
    function moduleOf(uint256 cellIndex) internal pure returns (bytes32) {
        CellDescriptor memory d = _descriptor(cellIndex);
        return d.moduleId;
    }

    /// @notice Coverage class of a cell, as the uint8 ordinal of `Coverage`.
    function coverageOf(uint256 cellIndex) internal pure returns (uint8) {
        CellDescriptor memory d = _descriptor(cellIndex);
        return d.coverage;
    }

    /// @notice Reduction rule a consumer must apply for a non-Direct cell.
    /// @dev `bytes32(0)` for Direct cells, whose post-state is a field copy.
    function reductionRuleIdOf(uint256 cellIndex) internal pure returns (bytes32) {
        CellDescriptor memory d = _descriptor(cellIndex);
        return d.reductionRuleId;
    }

    /// @notice Canonical, mutually exclusive event signatures that close a cell.
    /// @dev Never empty: `assertCatalogueComplete()` proves it, and `validate`
    ///      re-checks it before any record is published.
    function closingEventsOf(uint256 cellIndex) internal pure returns (bytes32[] memory) {
        CellDescriptor memory d = _descriptor(cellIndex);
        return d.closingEvents;
    }

    /// @notice Event signatures that re-describe a cell's delta as a cross-check.
    /// @dev A consumer MUST NOT apply these as sources; applying one is a
    ///      double-count bug the disjointness check in
    ///      `assertCatalogueComplete()` is designed to make impossible to express.
    function restatementsOf(uint256 cellIndex) internal pure returns (bytes32[] memory) {
        CellDescriptor memory d = _descriptor(cellIndex);
        return d.restatements;
    }

    /// @notice Commitment over a cell's ordered closing-event set.
    function closingSetRootOf(uint256 cellIndex) internal pure returns (bytes32) {
        return _setRoot(closingEventsOf(cellIndex));
    }

    /// @notice Commitment over a cell's ordered restatement set.
    function restatementSetRootOf(uint256 cellIndex) internal pure returns (bytes32) {
        return _setRoot(restatementsOf(cellIndex));
    }

    /// @notice True when the cell is closed by at least one canonical event.
    function isCellComplete(uint256 cellIndex) internal pure returns (bool) {
        CellDescriptor memory d = _descriptor(cellIndex);
        return d.closingEvents.length != 0;
    }

    // =========================================================================
    // Module accessors
    // =========================================================================

    /// @notice Registry module id of a module enumeration index.
    function moduleIdOf(uint256 moduleIndex) internal pure returns (bytes32) {
        if (moduleIndex >= MODULE_COUNT) revert IndexOutOfRange(moduleIndex);
        if (moduleIndex == 0) return MODULE_STAKE_CUSTODY;
        if (moduleIndex == 1) return MODULE_EVIDENCE;
        if (moduleIndex == 2) return MODULE_FINAL_REWARD_ALLOCATOR;
        if (moduleIndex == 3) return MODULE_AGGREGATION;
        if (moduleIndex == 4) return MODULE_SIGNATURE_NONCES;
        if (moduleIndex == 5) return MODULE_EMERGENCY_GATEKEEPER;
        if (moduleIndex == 6) return MODULE_CONSUMER_GUARANTEES;
        return MODULE_EVENT_COMPLETENESS;
    }

    /// @notice Number of authoritative read cells owned by a module.
    function cellCountOfModule(uint256 moduleIndex) internal pure returns (uint256) {
        if (moduleIndex >= MODULE_COUNT) revert IndexOutOfRange(moduleIndex);
        if (moduleIndex == 0) return 10;
        if (moduleIndex == 1) return 6;
        if (moduleIndex == 2) return 7;
        if (moduleIndex == 3) return 1;
        if (moduleIndex == 4) return 1;
        if (moduleIndex == 5) return 5;
        return 0;
    }

    /// @notice True when a module's state is fixed at construction, so it has no
    ///         mutable read cells and needs no per-mutation emissions.
    function isImmutableModule(uint256 moduleIndex) internal pure returns (bool) {
        if (moduleIndex >= MODULE_COUNT) revert IndexOutOfRange(moduleIndex);
        return moduleIndex >= 6;
    }

    /// @notice True when every authoritative storage mutation of a module emits
    ///         at least one canonical event. Vacuously true for immutable modules.
    function everyMutationEmitsOfModule(uint256 moduleIndex) internal pure returns (bool) {
        if (moduleIndex >= MODULE_COUNT) revert IndexOutOfRange(moduleIndex);
        return true;
    }

    // =========================================================================
    // Catalogue commitment
    // =========================================================================

    /// @notice Commitment over the whole ordered catalogue: domain separator,
    ///         then every cell's identity, module, coverage, reduction rule,
    ///         closing-set root and restatement-set root, in enumeration order.
    /// @dev Consumers pin this root at ingestion. Any added, removed, reordered,
    ///         or reclassified cell — or any change to a closing or restatement
    ///         set — changes it.
    function catalogueRoot() internal pure returns (bytes32 root) {
        root = CELL_DOMAIN;
        uint256 count = CELL_COUNT;
        for (uint256 i; i < count;) {
            CellDescriptor memory d = _descriptor(i);
            root = keccak256(
                abi.encode(
                    root,
                    keccak256(abi.encode(CELL_DOMAIN, d.moduleId, i)),
                    d.moduleId,
                    d.coverage,
                    d.reductionRuleId,
                    _setRoot(d.closingEvents),
                    _setRoot(d.restatements)
                )
            );
            unchecked {
                ++i;
            }
        }
    }

    // =========================================================================
    // Publication
    // =========================================================================

    /// @notice Returns the canonical record for one chain.
    function defaultRecord(uint64 chainId) internal pure returns (IEventCompleteness.EventCompleteness memory) {
        return IEventCompleteness.EventCompleteness({
            chainId: chainId,
            completenessVersion: COMPLETENESS_VERSION,
            moduleCount: MODULE_COUNT,
            cellCount: CELL_COUNT,
            bindingCount: bindingCount(),
            catalogueRoot: catalogueRoot(),
            everyMutationEmits: true,
            mutationsAreTerminal: true,
            orderIsTotal: true,
            projectionIsDeterministic: true
        });
    }

    /// @notice Reverts unless `record` is publishable.
    /// @dev Fail-closed and total: the record must bind a non-zero chain, the
    ///      supported enumeration version, and the exact canonical totals, and
    ///      all four semantic promises must hold. The catalogue checks run first,
    ///      so an incomplete or incoherent enumeration is rejected before any
    ///      field comparison can mask it.
    function validate(IEventCompleteness.EventCompleteness memory record) internal pure {
        assertCatalogueComplete();
        if (record.chainId == 0) revert InvalidRecord("chainId must be non-zero");
        if (record.completenessVersion != COMPLETENESS_VERSION) {
            revert InvalidRecord("unsupported completeness version");
        }
        if (record.moduleCount != MODULE_COUNT) revert InvalidRecord("moduleCount drift");
        if (record.cellCount != CELL_COUNT) revert InvalidRecord("cellCount drift");
        if (record.bindingCount != bindingCount()) revert InvalidRecord("bindingCount drift");
        if (record.catalogueRoot != catalogueRoot()) revert InvalidRecord("catalogueRoot drift");
        if (!record.everyMutationEmits) revert InvalidRecord("every authoritative mutation must emit");
        if (!record.mutationsAreTerminal) revert InvalidRecord("mutations must be terminal on emission");
        if (!record.orderIsTotal) revert InvalidRecord("canonical order must be total");
        if (!record.projectionIsDeterministic) revert InvalidRecord("projection replay must be deterministic");
    }

    /// @notice Reverts unless the catalogue is closed, disjoint, and coherent.
    /// @dev This is the machine-checked half of the completeness claim. The
    ///      other half — that no reachable read cell is missing from the
    ///      enumeration — is discharged by review and pinned by `catalogueRoot`.
    ///
    ///      Checks, in order: every cell is closed by at least one event; every
    ///      closing and restatement set is bounded; no event is both a source and
    ///      a restatement of the same cell; and every non-Direct cell publishes a
    ///      reduction rule while every Direct cell publishes none.
    function assertCatalogueComplete() internal pure {
        uint256 count = CELL_COUNT;
        for (uint256 i; i < count;) {
            CellDescriptor memory d = _descriptor(i);
            uint256 closing = d.closingEvents.length;
            uint256 restatements = d.restatements.length;

            if (closing == 0) revert UncoveredCell(i);
            if (closing > MAX_CLOSING_EVENTS || restatements > MAX_RESTATEMENTS) revert OversizedEventSet(i);
            if (_intersects(d.closingEvents, d.restatements)) revert AmbiguousCellEvent(i);

            bool direct = d.coverage == COVERAGE_DIRECT;
            if (direct != (d.reductionRuleId == bytes32(0))) revert IncoherentReductionRule(i);

            unchecked {
                ++i;
            }
        }
    }

    // =========================================================================
    // Ordered projection fold
    //
    // Consumers fold canonical event keys (see `V2Guarantees.eventKey`) in the
    // total order `(blockNumber, transactionIndex, logIndex)` into a single
    // commitment. Two consumers that applied the same catalogue to the same
    // canonical logs MUST arrive at the same root; any ordering, ordering-
    // dependency, or event-omission bug shows up as a root mismatch.
    // =========================================================================

    /// @notice Fold root of the empty canonical stream.
    bytes32 internal constant EMPTY_FOLD = keccak256("TRUTHBOUNTY.V2.EVENT_COMPLETENESS.EMPTY_FOLD.v1");

    /// @notice Advances the projection fold by one canonical event key.
    function replayFold(bytes32 previousFold, bytes32 eventKey) internal pure returns (bytes32) {
        return keccak256(abi.encode(previousFold, eventKey));
    }

    /// @notice True when `observedFold` is the exact successor of
    ///         `(previousFold, eventKey)`.
    function isFoldCanonical(bytes32 previousFold, bytes32 eventKey, bytes32 observedFold)
        internal
        pure
        returns (bool)
    {
        return replayFold(previousFold, eventKey) == observedFold;
    }

    // =========================================================================
    // Internals
    // =========================================================================

    function _setRoot(bytes32[] memory set) private pure returns (bytes32) {
        uint256 length = set.length;
        if (length == 0) return bytes32(0);
        return keccak256(abi.encode(set));
    }

    function _intersects(bytes32[] memory a, bytes32[] memory b) private pure returns (bool) {
        uint256 alen = a.length;
        uint256 blen = b.length;
        for (uint256 i; i < alen;) {
            for (uint256 j; j < blen;) {
                if (a[i] == b[j]) return true;
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
        return false;
    }

    function _descriptor(uint256 cellIndex) private pure returns (CellDescriptor memory d) {
        if (cellIndex == CELL_VAULT_SUPPORTED_ASSET) {
            d.moduleId = MODULE_STAKE_CUSTODY;
            d.coverage = COVERAGE_DIRECT;
            d.closingEvents = new bytes32[](1);
            d.closingEvents[0] = SIG_SUPPORTED_ASSET_UPDATED;
            d.restatements = new bytes32[](0);
            return d;
        }

        if (cellIndex == CELL_VAULT_LOCK_MUTATOR) {
            d.moduleId = MODULE_STAKE_CUSTODY;
            d.coverage = COVERAGE_DIRECT;
            d.closingEvents = new bytes32[](1);
            d.closingEvents[0] = SIG_LOCK_MUTATOR_UPDATED;
            d.restatements = new bytes32[](0);
            return d;
        }

        // Claimable balance: the primitive balance-moving events close the cell.
        // VaultSettledConclusive restates their sum and must not be applied.
        if (cellIndex == CELL_VAULT_CLAIMABLE) {
            d.moduleId = MODULE_STAKE_CUSTODY;
            d.coverage = COVERAGE_DIRECT;
            d.closingEvents = new bytes32[](5);
            d.closingEvents[0] = SIG_VAULT_DEPOSITED;
            d.closingEvents[1] = SIG_VAULT_LOCKED;
            d.closingEvents[2] = SIG_VAULT_UNLOCKED;
            d.closingEvents[3] = SIG_VAULT_WITHDRAWN;
            d.closingEvents[4] = SIG_PROTOCOL_ALLOCATION_CONSUMED;
            d.restatements = new bytes32[](1);
            d.restatements[0] = SIG_VAULT_SETTLED_CONCLUSIVE;
            return d;
        }

        if (cellIndex == CELL_VAULT_LOCKED_PRINCIPAL) {
            d.moduleId = MODULE_STAKE_CUSTODY;
            d.coverage = COVERAGE_DIRECT;
            d.closingEvents = new bytes32[](5);
            d.closingEvents[0] = SIG_VAULT_LOCKED;
            d.closingEvents[1] = SIG_VAULT_UNLOCKED;
            d.closingEvents[2] = SIG_VAULT_SLASHED;
            d.closingEvents[3] = SIG_VAULT_CARRIED_FORWARD;
            d.closingEvents[4] = SIG_VAULT_ROLLED_OVER;
            d.restatements = new bytes32[](0);
            return d;
        }

        if (cellIndex == CELL_VAULT_TOTAL_CUSTODY) {
            d.moduleId = MODULE_STAKE_CUSTODY;
            d.coverage = COVERAGE_DIRECT;
            d.closingEvents = new bytes32[](2);
            d.closingEvents[0] = SIG_VAULT_DEPOSITED;
            d.closingEvents[1] = SIG_VAULT_WITHDRAWN;
            d.restatements = new bytes32[](0);
            return d;
        }

        // Protocol allocation: the allocation-specific events close the cell;
        // VaultSlashed restates the credit leg of a slash.
        if (cellIndex == CELL_VAULT_PROTOCOL_ALLOCATION) {
            d.moduleId = MODULE_STAKE_CUSTODY;
            d.coverage = COVERAGE_DIRECT;
            d.closingEvents = new bytes32[](2);
            d.closingEvents[0] = SIG_PROTOCOL_ALLOCATION_INCREASED;
            d.closingEvents[1] = SIG_PROTOCOL_ALLOCATION_CONSUMED;
            d.restatements = new bytes32[](1);
            d.restatements[0] = SIG_VAULT_SLASHED;
            return d;
        }

        if (cellIndex == CELL_VAULT_ASSET_TOTAL_CLAIMABLE) {
            d.moduleId = MODULE_STAKE_CUSTODY;
            d.coverage = COVERAGE_AGGREGATE;
            d.reductionRuleId = RULE_SUM_OVER_PER_KEY;
            d.closingEvents = new bytes32[](5);
            d.closingEvents[0] = SIG_VAULT_DEPOSITED;
            d.closingEvents[1] = SIG_VAULT_LOCKED;
            d.closingEvents[2] = SIG_VAULT_UNLOCKED;
            d.closingEvents[3] = SIG_VAULT_WITHDRAWN;
            d.closingEvents[4] = SIG_PROTOCOL_ALLOCATION_CONSUMED;
            d.restatements = new bytes32[](1);
            d.restatements[0] = SIG_VAULT_SETTLED_CONCLUSIVE;
            return d;
        }

        if (cellIndex == CELL_VAULT_ASSET_TOTAL_LOCKED) {
            d.moduleId = MODULE_STAKE_CUSTODY;
            d.coverage = COVERAGE_AGGREGATE;
            d.reductionRuleId = RULE_SUM_OVER_PER_KEY;
            d.closingEvents = new bytes32[](3);
            d.closingEvents[0] = SIG_VAULT_LOCKED;
            d.closingEvents[1] = SIG_VAULT_UNLOCKED;
            d.closingEvents[2] = SIG_VAULT_SLASHED;
            d.restatements = new bytes32[](0);
            return d;
        }

        // Verifier stake: the Stake* family is canonical; the vault lock events
        // restate the same delta for the staking token under VERIFIER_PRINCIPAL.
        if (cellIndex == CELL_VAULT_VERIFIER_STAKE) {
            d.moduleId = MODULE_STAKE_CUSTODY;
            d.coverage = COVERAGE_AGGREGATE;
            d.reductionRuleId = RULE_STAKE_FAMILY_CANONICAL;
            d.closingEvents = new bytes32[](3);
            d.closingEvents[0] = SIG_STAKE_DEPOSITED;
            d.closingEvents[1] = SIG_STAKE_RELEASED;
            d.closingEvents[2] = SIG_STAKE_SLASHED;
            d.restatements = new bytes32[](3);
            d.restatements[0] = SIG_VAULT_LOCKED;
            d.restatements[1] = SIG_VAULT_UNLOCKED;
            d.restatements[2] = SIG_VAULT_SLASHED;
            return d;
        }

        if (cellIndex == CELL_VAULT_SETTLEMENT_OUTCOME) {
            d.moduleId = MODULE_STAKE_CUSTODY;
            d.coverage = COVERAGE_DERIVED;
            d.reductionRuleId = RULE_SETTLEMENT_OUTCOME_FROM_EVENT;
            d.closingEvents = new bytes32[](5);
            d.closingEvents[0] = SIG_VAULT_SETTLED_CONCLUSIVE;
            d.closingEvents[1] = SIG_VAULT_REFUNDED_INCONCLUSIVE;
            d.closingEvents[2] = SIG_VAULT_CARRIED_FORWARD;
            d.closingEvents[3] = SIG_VAULT_ROLLED_OVER;
            d.closingEvents[4] = SIG_VAULT_FINAL_UNLOCKED;
            d.restatements = new bytes32[](0);
            return d;
        }

        if (cellIndex == CELL_EVIDENCE_COMMITMENT) {
            d.moduleId = MODULE_EVIDENCE;
            d.coverage = COVERAGE_DIRECT;
            d.closingEvents = new bytes32[](2);
            d.closingEvents[0] = SIG_EVIDENCE_COMMITTED;
            d.closingEvents[1] = SIG_EVIDENCE_STATUS_CHANGED;
            d.restatements = new bytes32[](0);
            return d;
        }

        if (cellIndex == CELL_EVIDENCE_CLAIM_INDEX) {
            d.moduleId = MODULE_EVIDENCE;
            d.coverage = COVERAGE_AGGREGATE;
            d.reductionRuleId = RULE_SUM_OVER_PER_KEY;
            d.closingEvents = new bytes32[](1);
            d.closingEvents[0] = SIG_EVIDENCE_COMMITTED;
            d.restatements = new bytes32[](0);
            return d;
        }

        if (cellIndex == CELL_EVIDENCE_CONTRIBUTOR_NONCE) {
            d.moduleId = MODULE_EVIDENCE;
            d.coverage = COVERAGE_DERIVED;
            d.reductionRuleId = RULE_CONTRIBUTOR_NONCE_MONOTONIC;
            d.closingEvents = new bytes32[](1);
            d.closingEvents[0] = SIG_EVIDENCE_COMMITTED;
            d.restatements = new bytes32[](0);
            return d;
        }

        if (cellIndex == CELL_EVIDENCE_COMMITMENT_EXISTS) {
            d.moduleId = MODULE_EVIDENCE;
            d.coverage = COVERAGE_DERIVED;
            d.reductionRuleId = RULE_COMMITMENT_DEDUPE;
            d.closingEvents = new bytes32[](1);
            d.closingEvents[0] = SIG_EVIDENCE_COMMITTED;
            d.restatements = new bytes32[](0);
            return d;
        }

        if (cellIndex == CELL_EVIDENCE_STATUS) {
            d.moduleId = MODULE_EVIDENCE;
            d.coverage = COVERAGE_DERIVED;
            d.reductionRuleId = RULE_EVIDENCE_STATUS_FROM_COMMITMENT;
            // Both logs write the field: the commitment establishes SUBMITTED,
            // a status change overwrites it.
            d.closingEvents = new bytes32[](2);
            d.closingEvents[0] = SIG_EVIDENCE_COMMITTED;
            d.closingEvents[1] = SIG_EVIDENCE_STATUS_CHANGED;
            d.restatements = new bytes32[](0);
            return d;
        }

        if (cellIndex == CELL_EVIDENCE_PAUSED) {
            d.moduleId = MODULE_EVIDENCE;
            d.coverage = COVERAGE_DIRECT;
            d.closingEvents = new bytes32[](2);
            d.closingEvents[0] = SIG_EMERGENCY_PAUSE_ACTIVATED;
            d.closingEvents[1] = SIG_EMERGENCY_PAUSE_RECOVERED;
            d.restatements = new bytes32[](0);
            return d;
        }

        if (cellIndex == CELL_ALLOCATOR_FUNDED) {
            d.moduleId = MODULE_FINAL_REWARD_ALLOCATOR;
            d.coverage = COVERAGE_DIRECT;
            d.closingEvents = new bytes32[](1);
            d.closingEvents[0] = SIG_REWARD_POOL_FUNDED;
            d.restatements = new bytes32[](0);
            return d;
        }

        if (cellIndex == CELL_ALLOCATOR_ALLOCATED) {
            d.moduleId = MODULE_FINAL_REWARD_ALLOCATOR;
            d.coverage = COVERAGE_DIRECT;
            d.closingEvents = new bytes32[](1);
            d.closingEvents[0] = SIG_REWARDS_FINALIZED;
            d.restatements = new bytes32[](0);
            return d;
        }

        if (cellIndex == CELL_ALLOCATOR_CLAIMABLE) {
            d.moduleId = MODULE_FINAL_REWARD_ALLOCATOR;
            d.coverage = COVERAGE_DIRECT;
            d.closingEvents = new bytes32[](2);
            d.closingEvents[0] = SIG_REWARD_ALLOCATED;
            d.closingEvents[1] = SIG_REWARD_CLAIMED;
            d.restatements = new bytes32[](0);
            return d;
        }

        if (cellIndex == CELL_ALLOCATOR_SETTLEMENT_FUNDED) {
            d.moduleId = MODULE_FINAL_REWARD_ALLOCATOR;
            d.coverage = COVERAGE_AGGREGATE;
            d.reductionRuleId = RULE_SUM_OVER_PER_KEY;
            d.closingEvents = new bytes32[](1);
            d.closingEvents[0] = SIG_REWARD_POOL_FUNDED;
            d.restatements = new bytes32[](0);
            return d;
        }

        // Per-settlement allocation: RewardsFinalized writes the cell; the
        // per-recipient RewardAllocated logs restate its total.
        if (cellIndex == CELL_ALLOCATOR_SETTLEMENT_ALLOCATED) {
            d.moduleId = MODULE_FINAL_REWARD_ALLOCATOR;
            d.coverage = COVERAGE_AGGREGATE;
            d.reductionRuleId = RULE_SUM_OVER_PER_KEY;
            d.closingEvents = new bytes32[](1);
            d.closingEvents[0] = SIG_REWARDS_FINALIZED;
            d.restatements = new bytes32[](1);
            d.restatements[0] = SIG_REWARD_ALLOCATED;
            return d;
        }

        if (cellIndex == CELL_ALLOCATOR_FINALIZED) {
            d.moduleId = MODULE_FINAL_REWARD_ALLOCATOR;
            d.coverage = COVERAGE_DERIVED;
            d.reductionRuleId = RULE_FINALIZED_ON_FINALIZE;
            d.closingEvents = new bytes32[](1);
            d.closingEvents[0] = SIG_REWARDS_FINALIZED;
            d.restatements = new bytes32[](0);
            return d;
        }

        if (cellIndex == CELL_ALLOCATOR_FINAL_OUTCOME) {
            d.moduleId = MODULE_FINAL_REWARD_ALLOCATOR;
            d.coverage = COVERAGE_DIRECT;
            d.closingEvents = new bytes32[](1);
            d.closingEvents[0] = SIG_REWARDS_FINALIZED;
            d.restatements = new bytes32[](0);
            return d;
        }

        if (cellIndex == CELL_AGGREGATION_OUTCOME) {
            d.moduleId = MODULE_AGGREGATION;
            d.coverage = COVERAGE_DIRECT;
            d.closingEvents = new bytes32[](1);
            d.closingEvents[0] = SIG_AGGREGATION_FINALIZED;
            d.restatements = new bytes32[](0);
            return d;
        }

        if (cellIndex == CELL_NONCE_BITMAP) {
            d.moduleId = MODULE_SIGNATURE_NONCES;
            d.coverage = COVERAGE_DIRECT;
            d.closingEvents = new bytes32[](2);
            d.closingEvents[0] = SIG_NONCE_CONSUMED;
            d.closingEvents[1] = SIG_NONCE_CANCELLED;
            d.restatements = new bytes32[](0);
            return d;
        }

        // Scope pause: ScopePauseUpdated carries the boolean explicitly;
        // EmergencyPaused/EmergencyUnpaused restate the same transition.
        if (cellIndex == CELL_EMERGENCY_SCOPE_PAUSED) {
            d.moduleId = MODULE_EMERGENCY_GATEKEEPER;
            d.coverage = COVERAGE_DIRECT;
            d.closingEvents = new bytes32[](1);
            d.closingEvents[0] = SIG_SCOPE_PAUSE_UPDATED;
            d.restatements = new bytes32[](2);
            d.restatements[0] = SIG_EMERGENCY_PAUSED;
            d.restatements[1] = SIG_EMERGENCY_UNPAUSED;
            return d;
        }

        if (cellIndex == CELL_EMERGENCY_SCOPE_MAX_LEVEL) {
            d.moduleId = MODULE_EMERGENCY_GATEKEEPER;
            d.coverage = COVERAGE_DIRECT;
            d.closingEvents = new bytes32[](1);
            d.closingEvents[0] = SIG_SCOPE_MAX_PAUSE_LEVEL_SET;
            d.restatements = new bytes32[](0);
            return d;
        }

        if (cellIndex == CELL_EMERGENCY_CONTROLLER) {
            d.moduleId = MODULE_EMERGENCY_GATEKEEPER;
            d.coverage = COVERAGE_DIRECT;
            d.closingEvents = new bytes32[](1);
            d.closingEvents[0] = SIG_EMERGENCY_CONTROLLER_REWIRED;
            d.restatements = new bytes32[](0);
            return d;
        }

        // Rewire delay: only setEmergencyRewireDelay writes the cell;
        // EmergencyControllerRewired merely reports the current value.
        if (cellIndex == CELL_EMERGENCY_REWIRE_DELAY) {
            d.moduleId = MODULE_EMERGENCY_GATEKEEPER;
            d.coverage = COVERAGE_DIRECT;
            d.closingEvents = new bytes32[](1);
            d.closingEvents[0] = SIG_EMERGENCY_REWIRE_DELAY_UPDATED;
            d.restatements = new bytes32[](1);
            d.restatements[0] = SIG_EMERGENCY_CONTROLLER_REWIRED;
            return d;
        }

        if (cellIndex == CELL_EMERGENCY_LAST_REWIRE) {
            d.moduleId = MODULE_EMERGENCY_GATEKEEPER;
            d.coverage = COVERAGE_DERIVED;
            d.reductionRuleId = RULE_REWIRE_TIMESTAMP_FROM_BLOCK;
            d.closingEvents = new bytes32[](1);
            d.closingEvents[0] = SIG_EMERGENCY_CONTROLLER_REWIRED;
            d.restatements = new bytes32[](0);
            return d;
        }

        revert IndexOutOfRange(cellIndex);
    }
}
