// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IEventCompleteness
/// @notice Authoritative on-chain declaration that every authoritative storage
///         mutation of the canonical V2 protocol emits enough ordered
///         information for a clean indexer to reconstruct canonical read state
///         from logs alone.
/// @dev V2-SC-132. The record published by this interface is the single source
///      of truth for projection replay. Off-chain consumers (indexers, APIs,
///      analytics, explorers) MUST read the record on-chain, or from a
///      deployment manifest pinned to a commit and chain ID, and MUST NOT
///      hardcode independent assumptions about which cells exist, which event
///      closes them, or how aggregates are derived.
///
///      Publication confers no authority. The completeness record is a promise
///      about the log surface only: reading it, replaying it, or enforcing it
///      on-chain never grants settlement, treasury, or configuration power to
///      any consumer, and this interface exposes no state-changing function.
///      Reorg and rollback semantics are governed separately by
///      `IConsumerGuarantees`; this interface covers only "does the canonical
///      stream carry enough information to rebuild read state".
interface IEventCompleteness {
    // =========================================================================
    // Coverage vocabulary
    // =========================================================================

    /// @notice How a canonical read cell is closed by the event stream.
    /// @dev Carried as uint8 in `CellCoverage.coverage` so that validation is a
    ///      real, reachable check: an out-of-range native enum reverts at the
    ///      ABI/memory boundary before any library guard could run.
    enum Coverage {
        /// @notice The cell's post-state is written verbatim in the payload of a
        ///         canonical event. Replay is a field copy, so no reduction rule
        ///         is published (`reductionRuleId == bytes32(0)`).
        Direct,
        /// @notice The cell is a sum over per-key cells; replay accumulates the
        ///         per-key events in canonical order. A reduction rule id is
        ///         published.
        Aggregate,
        /// @notice The cell is a pure function of other cells plus the block
        ///         context of the log. A reduction rule id is published.
        Derived
    }

    /// @notice One authoritative read cell of the canonical V2 protocol, the
    ///         canonical events that close it, and the events that restate it.
    /// @dev A "cell" is the smallest independently queryable unit of canonical
    ///      read state: `staked(claimId, account)`, `claimableBalance(asset,
    ///      account)`, `nextContributorNonce(contributor)`, and so on. The
    ///      completeness claim is exactly: (a) every cell listed here is closed
    ///      by at least one canonical event, and (b) no cell reachable through a
    ///      public read function of a canonical V2 module is absent from the
    ///      list. `catalogueRoot` binds the whole enumeration so either half
    ///      failing is detectable as drift.
    ///
    ///      Restatements matter as much as sources. Several canonical modules
    ///      describe one state delta twice — a primitive and a summary emission,
    ///      or a cell-specific and a general one. A consumer MUST apply only the
    ///      closing set; the restatement set is a cross-check. Publishing both
    ///      sets, and their disjointness, is what makes double counting a
    ///      detectable mistake instead of a silent one.
    struct CellCoverage {
        /// @notice Stable identity of the cell:
        ///         `keccak256(abi.encode(CELL_DOMAIN, moduleId, cellIndex))`.
        bytes32 cellId;
        /// @notice Registry module id that owns the cell.
        bytes32 moduleId;
        /// @notice Position of the cell inside the global cell enumeration.
        uint256 cellIndex;
        /// @notice Coverage class, as the uint8 ordinal of `Coverage`.
        uint8 coverage;
        /// @notice Number of canonical event signatures that close the cell.
        ///         Always >= 1: a zero-length binding set is the incompleteness
        ///         this interface exists to exclude.
        uint256 closingEventCount;
        /// @notice Keccak commitment over the ordered closing-event signatures.
        /// @dev Binds the catalogue to the exact signatures a consumer must
        ///      decode, so an added, removed, or reordered emission shows up as
        ///      drift instead of being silently ignored.
        bytes32 closingSetRoot;
        /// @notice Reduction rule a consumer must apply for a non-Direct cell.
        ///         `bytes32(0)` exactly when `coverage == Coverage.Direct`.
        /// @dev Publishing the rule id lets a consumer prove it applied the
        ///      intended reduction rather than an ad-hoc one; it is pinned by
        ///      `catalogueRoot`.
        bytes32 reductionRuleId;
        /// @notice Number of event signatures that restate the same delta and
        ///         are therefore cross-checks rather than sources. May be zero.
        uint256 restatementCount;
        /// @notice Keccak commitment over the ordered restatement signatures.
        ///         `bytes32(0)` for a cell with no restatements.
        bytes32 restatementSetRoot;
    }

    /// @notice One canonical V2 module and its completeness posture.
    struct ModuleCoverage {
        /// @notice Registry module id.
        bytes32 moduleId;
        /// @notice Number of authoritative read cells owned by the module.
        uint256 cellCount;
        /// @notice True when every authoritative storage mutation in the module
        ///         emits at least one canonical event. Vacuously true for
        ///         `isImmutable` modules, which have no mutable read state.
        bool everyMutationEmits;
        /// @notice True when the module's state is fixed at construction, so
        ///         the absence of per-mutation events is by construction rather
        ///         than by omission.
        bool isImmutable;
    }

    /// @notice The deployment-pinned completeness claim.
    /// @dev Every field is a promise about the emitted log surface. The record
    ///      is bound to exactly one chain; it is never valid across deployments.
    struct EventCompleteness {
        /// @notice Chain this record is valid for.
        uint64 chainId;
        /// @notice Enumeration version of the cell catalogue.
        uint16 completenessVersion;
        /// @notice Number of canonical modules covered.
        uint256 moduleCount;
        /// @notice Number of authoritative read cells enumerated by the record.
        uint256 cellCount;
        /// @notice Total number of cell/event bindings across all cells.
        ///         Counts closing sources only: a restatement is a cross-check,
        ///         not a source. Bounded by `V2EventCompleteness.MAX_BINDINGS`.
        uint256 bindingCount;
        /// @notice Keccak commitment over the ordered cell enumeration and each
        ///         cell's module, coverage, reduction rule, closing-set root and
        ///         restatement-set root.
        /// @dev Consumers store this root at ingestion and re-derive it on every
        ///      replay; a mismatch means the projection is being built against a
        ///      catalogue that no longer describes the stream.
        bytes32 catalogueRoot;
        /// @notice True when every authoritative storage mutation emits at
        ///         least one canonical event. Required for the canonical V2
        ///         surface; a record asserting false is rejected.
        bool everyMutationEmits;
        /// @notice True when canonical events are emitted only after the state
        ///         transition they describe has succeeded, so a reverted
        ///         transaction never produces a log. Required.
        bool mutationsAreTerminal;
        /// @notice True when the canonical total order
        ///         `(blockNumber, transactionIndex, logIndex)` is the only order
        ///         a consumer needs. Required.
        bool orderIsTotal;
        /// @notice True when replaying the canonical stream is deterministic: no
        ///         emission depends on off-chain, block-hash-bound, or otherwise
        ///         non-reproducible input. Required.
        bool projectionIsDeterministic;
    }

    /// @notice Emitted once at deployment when the completeness record becomes
    ///         readable on-chain. Consumers may index on this event to discover
    ///         the authoritative record without calling the getter.
    event EventCompletenessPublished(EventCompleteness completeness);

    /// @notice Returns the immutable completeness record for this deployment.
    /// @dev The single source of truth for projection replay. Callers MUST
    ///      reject a record whose `chainId` disagrees with the chain they index.
    function eventCompleteness() external view returns (EventCompleteness memory);

    /// @notice Returns one page of cell coverage entries in enumeration order.
    /// @dev Bounded by construction: `limit` is capped on-chain and the returned
    ///      slice never exceeds the cap, so no call performs an unbounded loop
    ///      regardless of the total cell count.
    /// @param cursor First cell index to return; must be below `cellCount`.
    /// @param limit Requested page size; must be within
    ///        `[1, V2EventCompleteness.MAX_COVERAGE_PAGE_SIZE]`.
    function cellCoverage(uint256 cursor, uint256 limit) external view returns (CellCoverage[] memory page);

    /// @notice Returns the coverage posture of one canonical module.
    /// @dev Constant-time lookup; the module enumeration is bounded by
    ///      `V2EventCompleteness.MAX_MODULES`.
    /// @param index Module enumeration index; must be below `moduleCount`.
    function moduleCoverage(uint256 index) external view returns (ModuleCoverage memory);
}
