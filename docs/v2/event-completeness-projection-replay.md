# V2 Event Completeness For Projection Replay

**Issue:** V2-SC-132
**Status:** Normative
**Catalogue root (testnet, chain 11155420):** `0xdd8947a68c9ca89956a3dd37245426b8e8f84cd0c23668d6c5c7d4b78d18138c`

This document is the consumer-facing contract for V2-SC-132. It defines what a
consumer must know to rebuild every authoritative read cell of the canonical V2
modules from the ordered log stream alone, with no `eth_call`, no storage read,
and no off-chain inference.

Events remain read-only evidence of state the contracts already enforce. Nothing
in this specification grants a consumer settlement, treasury, or configuration
authority, and no event is an input to a protocol state transition.

---

## 1. The Catalogue

`contracts/v2/libraries/V2EventCompleteness.sol` is the single source of truth.
`EventCompletenessAnchor` publishes it on-chain at deploy time, and
`deployments/config/event-completeness.json` is its off-chain mirror.

| Quantity | Value |
|----------|-------|
| Module count | 8 |
| Cell count | 30 |
| Closing bindings | 57 |
| Restatements | 10 |
| Reduction rules | 8 |
| Cell domain | `0x4f62b94915b10b8d93b9383b644a52a452d96836d17d6e4e46df913917d0b100` |

A **cell** is one authoritative read field, or the exact reduction of a family of
them. Cells are the unit of completeness: a cell is *closed* when at least one
canonical event carries its delta, and the catalogue fails closed
(`assertCatalogueComplete`) if any cell is empty, any cell's source set overlaps
its restatement set, or any rule/coverage pairing is incoherent.

### 1.1 Modules

| Index | Module | Module id | Cells | Mutable |
|-------|--------|-----------|-------|---------|
| 0 | `STAKE_CUSTODY` | `0xc975f1b1…` | 10 | yes |
| 1 | `EVIDENCE` | `0x7477535a…` | 6 | yes |
| 2 | `FINAL_REWARD_ALLOCATOR` | `0xc38c186e…` | 7 | yes |
| 3 | `AGGREGATION` | `0x9a0e9d68…` | 1 | yes |
| 4 | `SIGNATURE_NONCES` | `0x7db146fe…` | 1 | yes |
| 5 | `EMERGENCY_GATEKEEPER` | `0x6256cf20…` | 5 | yes |
| 6 | `CONSUMER_GUARANTEES` | `0xb0637449…` | 0 | immutable |
| 7 | `EVENT_COMPLETENESS` | `0x65644956…` | 0 | immutable |

The two immutable modules have no cells because they carry no mutable state:
their content is fixed at construction and published in full by their own
deployment events.

### 1.2 Cells

| Idx | Cell | Read surface | Coverage | Rule |
|-----|------|--------------|----------|------|
| 0 | vault supported asset | `supportedAssets(address)` | Direct | — |
| 1 | vault lock mutator | `lockMutators(address)` | Direct | — |
| 2 | claimable balance | `claimableBalance(address,address)` | Direct | — |
| 3 | locked principal | `lockedPrincipal(...)` | Direct | — |
| 4 | total custody | `totalCustody(address)` | Direct | — |
| 5 | protocol allocation | `protocolAllocation(address)` | Direct | — |
| 6 | asset total claimable | `reconcile` / `conservation` | Aggregate | R0 |
| 7 | asset total locked | `reconcile` / `conservation` | Aggregate | R0 |
| 8 | verifier stake | `staked(claimId,account)` | Aggregate | R6 |
| 9 | settlement outcome | `settlementOutcome(claimId,round)` | Derived | R3 |
| 10 | evidence commitment | `getEvidenceCommitment(uint256)` | Direct | — |
| 11 | evidence per-claim index | `evidenceCount` / `claimEvidence` | Aggregate | R0 |
| 12 | contributor nonce | `nextContributorNonce(address)` | Derived | R1 |
| 13 | commitment dedupe set | `DuplicateEvidence` revert | Derived | R2 |
| 14 | evidence status | `getEvidence(id).status` | Derived | R7 |
| 15 | evidence paused | `paused()` | Direct | — |
| 16 | allocator funded | allocator pool view | Direct | — |
| 17 | allocator allocated | allocator allocation view | Direct | — |
| 18 | allocator claimable | `RewardClaimed` balance view | Direct | — |
| 19 | per-settlement funded | per-settlement funding | Aggregate | R0 |
| 20 | per-settlement allocated | per-settlement allocation | Aggregate | R0 |
| 21 | settlement finalized | finalization flag | Derived | R4 |
| 22 | final outcome | final allocation outcome | Derived | R3 |
| 23 | aggregation outcome | aggregate verdict | Direct | — |
| 24 | signature nonce bitmap | nonce bitmap | Direct | — |
| 25 | emergency scope paused | per-scope pause flag | Direct | — |
| 26 | emergency max level | per-scope max level | Direct | — |
| 27 | emergency controller | per-scope controller | Direct | — |
| 28 | emergency rewire delay | per-scope rewire delay | Direct | — |
| 29 | emergency last rewire | per-scope rewire timestamp | Derived | R5 |

---

## 2. Coverage Classes

Every cell declares exactly one coverage class, and the class determines what a
consumer must do.

**`Direct` (ordinal 0).** The cell's post-state is a copy of a field carried by
one of its closing events. Apply the event's payload; nothing else.

**`Aggregate` (ordinal 1).** The cell is the sum of its per-key cells over a
published key set. Apply the reduction rule; do not invent a second event family
for the total. All aggregate cells use R0.

**`Derived` (ordinal 2).** The cell is a function of other cells and events — a
derived flag, an identity, or a default. Apply the published rule. A `Derived`
cell has no field copy, so a consumer that skips the rule produces a wrong answer
rather than a missing one.

`bytes32(0)` as `reductionRuleId` is legal only for `Direct` cells, and
`validate` re-checks this pairing before any record is published.

---

## 3. Closing Events And Restatements

A cell's **closing events** are its sources: they are mutually exclusive for that
cell's delta, and a consumer applies them. A cell's **restatements** re-describe
the same delta in a different vocabulary. They are cross-checks only.

> A consumer MUST NOT apply a restatement as a source. Doing so double-counts.

The catalogue enforces this structurally: `assertCatalogueComplete()` reverts if a
cell's closing set and restatement set intersect, so the two roles cannot be
confused for the same cell. The two sets may still name the same *event* for
different cells, which is how a single log legitimately feeds several cells.

The ten restatements in this catalogue:

| Cell | Restatements | Closed by |
|------|--------------|-----------|
| 2, 6 | `VaultSettledConclusive` | `VaultUnlocked` + `ProtocolAllocationConsumed` |
| 5 | `VaultSlashed` | `ProtocolAllocationIncreased` |
| 8 | `VaultLocked`, `VaultUnlocked`, `VaultSlashed` | the `Stake*` family |

Cell 5's restatement is the clearest case: `_slash` emits `VaultSlashed` and then
`ProtocolAllocationIncreased` for one credit. Only the latter is the source.

`test/v2/ProjectionReplay.t.sol` pins this with a negative control: a projection
that also applies restatements is shown to diverge from the contracts' own views.

---

## 4. Reduction Rules

Eight rules are published by name and by id, where the id is
`keccak256(abi.encode(bytes(name)))`. A rule id a consumer cannot resolve by name
is a catalogue bug, and `test_ManifestCoverageAndRuleAreCoherent` fails on one.

| Rule | Name | Formula |
|------|------|---------|
| R0 | `R0:sum-over-per-key-cells` | Sum the per-key cells in canonical key order. |
| R1 | `R1:contributor-nonce-monotonic` | `max(observed nonce) + 1` over the contributor's ordered `EvidenceCommitted` stream. |
| R2 | `R2:commitment-dedupe` | The flag is set once a log exists with matching `(claimId, contributor, contentDigest, metadataDigest)`. |
| R3 | `R3:settlement-outcome-from-event` | The outcome is the identity of the settlement event that closed the `(claimId, round)` cell; `NONE` until one arrives. |
| R4 | `R4:finalized-on-rewards-finalized` | The finalized flag is set once `RewardsFinalized` is observed for the settlement id. |
| R5 | `R5:rewire-timestamp-from-block` | The rewire timestamp is the **block** of the log that last wrote the controller, never the log's own `timestamp` field. |
| R6 | `R6:stake-family-canonical-vault-locks-restate` | The `Stake*` family is canonical for the verifier-stake cell; the vault lock family restates the same delta. |
| R7 | `R7:evidence-status-defaults-submitted-at-commit` | A record's status is `SUBMITTED` from its `EvidenceCommitted` log until an `EvidenceStatusChanged` log overwrites it; the record is absent before the commitment. |

R5 and R6 exist because a log's `timestamp` field is proposer-influenceable and
because two vocabularies describe one delta. R7 exists because a commitment log
carries no status field: publishing only the status *change* would leave a
consumer unable to distinguish a committed record in `SUBMITTED` from one whose
status it never observed.

---

## 5. Roots And Ordering

```
cellId(i)            = keccak256(abi.encode(cellDomain, moduleId(i), i))
closingSetRoot(c)    = kecc256(abi.encode(bytes32[] closingEvents(c)))   // bytes32(0) when empty
restatementSetRoot(c)= kecc256(abi.encode(bytes32[] restatements(c)))    // bytes32(0) when empty
catalogueRoot        = fold over i of
                      keccak256(abi.encode(prev, cellId(i), moduleId(i), coverage(i),
                                            reductionRuleId(i), closingSetRoot(i), restatementSetRoot(i)))
                      seeded with cellDomain
```

Set roots are order-sensitive: the element order in the library is canonical and
a reordering changes the root. The catalogue root is the consumer's pin — any
added, removed, reordered, or reclassified cell, and any change to a closing or
restatement set, changes it.

**Total order.** `(blockNumber, transactionIndex, logIndex)`. Never a weaker
order. Event identity for the projection fold is
`keccak256(abi.encode(chainId, contractAddress, blockNumber, blockHash, transactionHash, logIndex))`
(`V2Guarantees.eventKey`, V2-SC-134); the fold is
`replayFold(previousFold, eventKey)` seeded with `EMPTY_FOLD`
(`0x05e832d6b293d0608237b105d14f8d3a82ff27c8df477f1d3773b32ff02cb69d`).

**Block-derived fields.** A consumer that needs the block number or timestamp of
a transition MUST take the block number from the receipt, not the log. The log's
own `timestamp` is untrusted for ordering and rewind purposes.

---

## 6. The Publication Record

`EventCompletenessAnchor` is immutable after construction, read-only, and grants
no authority. It exposes `eventCompleteness()`, `moduleCoverage(i)`, and
`cellCoverage(i)`, and emits `EventCompletenessPublished` at deploy time with the
record, the chain id, the deployer, and the block.

`CellCoverage` carries `closingEvents`, `restatementCount`, `restatementSetRoot`,
`coverage`, and `reductionRuleId`, so a consumer can verify one cell without
walking the whole catalogue. `bindingCount` counts closing bindings only; the
catalogue root binds both event-set roots and the rule.

`validate` is fail-closed and total. A record is publishable only when it binds a
non-zero chain, the supported enumeration version, the exact canonical totals
(`moduleCount`, `cellCount`, `bindingCount`, `catalogueRoot`), and all four
semantic promises:

| Promise | Meaning |
|---------|---------|
| `everyMutationEmits` | Every mutation of every cell emits a canonical closing event. |
| `mutationsAreTerminal` | A replayed transition cannot be un-applied by a later log. |
| `orderIsTotal` | The declared total order is a strict order over the stream. |
| `projectionIsDeterministic` | The same stream and the same order always produce the same state. |

The catalogue checks run before any field comparison, so an incoherent
enumeration is rejected before a field match can mask it.

---

## 7. Consumer Algorithm

1. Read the record from the anchor at ingest; pin `catalogueRoot`,
   `closingSetRoot`, and `restatementSetRoot`.
2. Reject a record whose `chainId` differs from the chain being indexed.
3. Filter by module contract address and canonical signature, then order by
   `(blockNumber, transactionIndex, logIndex)`.
4. For each log, find the cell it closes. Apply the closing delta. If the log is a
   restatement for that cell, record it as a cross-check only.
5. Apply the cell's published `reductionRuleId` for every `Aggregate` or `Derived`
   cell. Do not substitute an ad-hoc reduction.
6. Reconcile aggregates from per-key cells and assert conservation before serving
   reads.
7. Quarantine any signature the catalogue does not name. Never silently ignore an
   unlisted emission.

### 7.1 Non-canonical emissions

These logs are emitted by the modules and are deliberately **not** closing
sources. A consumer may ignore them. They are published machine-readably in
`nonCanonicalEmissions` in the manifest, with the `topic0`, the signature, and
the reason; the manifest suite pins the list, asserts no allow-listed emission
closes a cell, and the replay suite asserts its own allow-list is a subset of the
manifest's. A genuinely new emission therefore cannot hide among them.

| Log | Why it is not a source |
|-----|------------------------|
| `EvidenceSubmitted`, `EvidenceSubmittedV1` | Superseded by `EvidenceCommitted`, which additionally carries the metadata digest, the nonce, and the schema version. |
| `Paused`, `Unpaused` | OpenZeppelin's inherited `Pausable` base; cell 15 is closed by `EmergencyPauseActivatedV1` / `EmergencyPauseRecoveredV1`. |
| `RoleGranted`, `RoleRevoked` | AccessControl bookkeeping with no read cell of its own. |
| `ModuleRegistered`, `ModuleRemoved` | Registry bookkeeping; module membership is read from the registry. |

---

## 8. Verification

| Property | Test |
|----------|------|
| Every cell is closed; sets are disjoint; rule/coverage pairs are coherent; record is publishable | `test/v2/EventCompleteness.t.sol` (41 tests) |
| The manifest is byte-for-byte derived from the library, including roots and the rule vocabulary | `test/v2/EventCompletenessManifest.t.sol` (18 tests) |
| A real vault and registry log stream replays into the contracts' own view values for all 30 cells | `test/v2/ProjectionReplay.t.sol` |
| Applying restatements as sources over-counts | `test/v2/ProjectionReplay.t.sol::test_ApplyingRestatementsAsSourcesDoubleCounts` |
| Every emission is a published source or an allow-listed non-canonical log | `test/v2/ProjectionReplay.t.sol::test_EmissionsAreEitherPublishedClosingEventsOrDocumentedLegacyLogs` |
| Every allow-listed non-canonical emission is published in the manifest, and closes no cell | `test/v2/EventCompletenessManifest.t.sol::test_ManifestPublishesNonCanonicalEmissions`, `::test_NonCanonicalEmissionsCloseNoCell` |
| A randomized custody history replays to the contracts' view values on both assets, categories, and rounds | `test/fuzz/ProjectionReplayFuzz.t.sol::testFuzz_ReplayMatchesStorage` |
| R0 aggregate cells equal the sum over their per-key cells plus protocol allocation | `test/fuzz/ProjectionReplayFuzz.t.sol::testFuzz_AggregateReducesToPerKeySums` |
| R6 stake cell equals the sum over per-actor stake cells | `test/fuzz/ProjectionReplayFuzz.t.sol::testFuzz_StakeCellReducesToPerKeySums` |
| A partial withdrawal leaves the conservation equation intact for a fuzzer-chosen remainder | `test/fuzz/ProjectionReplayFuzz.t.sol::testFuzz_PartialWithdrawalConservesCustody` |
| The projection fold is deterministic, and re-observing a consumed key is a detectable non-canonical transition | `test/fuzz/ProjectionReplayFuzz.t.sol::testFuzz_ReplayFoldIsDeterministic`, `::testFuzz_ReplayingAConsumedKeyIsNotCanonical` |

`test/v2/ProjectionReplay.t.sol` contains `LogProjection`, a reference indexer
that imports nothing from the protocol: it consumes only `(topic0, topics, data,
blockNumber)` tuples, which is exactly what a real indexer has. Any cell a
consumer cannot rebuild without an `eth_call` is a gap in this catalogue, and
that test is where the gap shows up.
