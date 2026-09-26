# Event consumer compatibility checklist

Indexer, backend, frontend, explorer, and analytics consumers should apply the following rules to the SC-022 event surface.

Reorganization expectations (confirmation depth, finality classes, bounded replacement/removal, and replay) are now authoritative and machine-readable: see [`docs/reorg-consumer-guarantees.md`](./reorg-consumer-guarantees.md) and the on-chain `IConsumerGuarantees` anchor. The rules below remain valid; the guarantees document makes them normative.

- Filter by contract address and canonical event signature before decoding.
- Treat indexed entity identifiers and actors as the primary query keys.
- Persist block number, block hash, transaction hash, transaction index, and log index with every decoded event.
- Deduplicate by chain ID, transaction hash, and log index.
- Delay irreversible processing until the consumer's configured confirmation depth is reached.
- Roll back events whose block hash is no longer canonical after a reorganization.
- Reject unsupported schema versions without corrupting previously indexed state.
- Process logs in block number, transaction index, then log index order.
- Never infer a successful state transition from a reverted transaction; reverted transactions produce no logs.
- Treat metadata hashes as references and verify fetched metadata independently.

Schema version `1` is the initial compatibility target.

---

## Canonical V2 projection replay (V2-SC-132)

Consumers of the canonical V2 modules must also apply the following. The
machine-readable catalogue is published on-chain by the read-only
`EventCompletenessAnchor` and mirrored in
[`deployments/config/event-completeness.json`](../deployments/config/event-completeness.json);
the normative rules are in
[`docs/v2/event-completeness-projection-replay.md`](./v2/event-completeness-projection-replay.md).

Current published catalogue: 8 modules, 30 cells, 57 closing bindings, 10
restatements, 8 reduction rules, catalogue root
`0xdd8947a68c9ca89956a3dd37245426b8e8f84cd0c23668d6c5c7d4b78d18138c`.

- Pin `catalogueRoot`, `closingSetRoot`, and `restatementSetRoot` at ingestion and re-derive all three on every replay; treat any drift as a catalogue change, not as consumer drift.
- Apply a cell's `closingEvents` as its sources. Treat its `restatements` as cross-checks and never as sources — applying both double-counts, which `test_ApplyingRestatementsAsSourcesDoubleCounts` demonstrates.
- Apply the cell's published `reductionRuleId` for every `Aggregate` or `Derived` cell. An ad-hoc reduction will disagree with the anchor on at least one of the eight rules.
- Reconstruct the verifier-stake cell from the `Stake*` family only (R6). The vault lock events restate the same delta.
- Read `EvidenceCommitted` as establishing status `SUBMITTED`, then apply `EvidenceStatusChanged` to overwrite it (R7). A consumer that watches only the status-change event cannot distinguish a committed record in `SUBMITTED` from a record it never observed.
- Take a transition's block number and timestamp from the receipt, never from the log's own `timestamp` field, which is proposer-influenceable (R5).
- Re-derive the projection fold with `V2EventCompleteness.replayFold` from `EMPTY_FOLD` and compare it to your own. A mismatch means a log was applied twice, skipped, or applied out of order.
- Assert conservation before serving a read: `claimable + locked + protocolAllocation == totalCustody` for every asset, summed over the per-key cells.
- Do not decode these documented non-canonical emissions: `EvidenceSubmitted`, `EvidenceSubmittedV1`, `Paused`, `Unpaused`, `RoleGranted`, `RoleRevoked`, `ModuleRegistered`, `ModuleRemoved`. They are published machine-readably in `nonCanonicalEmissions` in the manifest, with each `topic0` and its reason. Quarantine anything outside that list and the catalogue; never silently ignore an unlisted emission.
- Reject a record whose chain id disagrees with the chain being indexed.
