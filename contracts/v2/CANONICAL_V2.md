# Canonical V2 Protocol Contracts

**Status:** ✅ CANONICAL V2 BASELINE  
**Protocol Version:** 2.0  
**Last Verified:** September 24, 2026

---

## Directory Purpose

This directory contains the **canonical V2 protocol contracts** that form the foundation of TruthBounty's modular verification system.

All contracts in this directory:
- ✅ Implement `IV2Module` interface
- ✅ Return protocol version 2.0 via `protocolVersion()`
- ✅ Follow modular architecture patterns
- ✅ Use standardized V2 interfaces
- ✅ Are free of Stellar/Soroban/Freighter dependencies
- ✅ Are approved for production deployment (after audit)

---

## Canonical V2 Contracts

### Core Modules

| Contract | Status | Purpose | Interfaces |
|----------|--------|---------|------------|
| **EvidenceRegistry.sol** | ✅ CANONICAL | Content-addressed evidence commitment registry | `IV2Module`, `IEvidence` |
| **StakeVault.sol** | ✅ CANONICAL | Multi-asset stake custody and settlement | `IV2Module`, `IStakeCustody` |
| **EventCompletenessAnchor.sol** | ✅ CANONICAL | Read-only publication of the event-completeness catalogue (V2-SC-132) | `IV2Module`, `IEventCompleteness` |

### Event Completeness Anchor

`EventCompletenessAnchor` is immutable after construction and carries no
settlement, treasury, or configuration authority. It publishes the 30-cell
catalogue that lets a consumer rebuild every authoritative read cell of the
canonical modules from the ordered log stream alone.

- `eventCompleteness()` returns the pinned record: chain id, enumeration version, module/cell/binding totals, the catalogue root, and the four semantic promises.
- `moduleCoverage(i)` and `cellCoverage(i)` return per-module and per-cell coverage, including `closingEvents`, `restatementCount`, `restatementSetRoot`, `coverage`, and `reductionRuleId`.
- `cellSources(i)` returns those per-cell bindings with the restatement events expanded, so a consumer can verify one cell without walking the catalogue.
- `EventCompletenessPublished` is emitted once, at deploy time, with the record, chain id, deployer, and block.

`V2EventCompleteness` is the single source of truth for the catalogue, and
`deployments/config/event-completeness.json` is its off-chain mirror. Published
totals: 8 modules, 30 cells, 57 closing bindings, 10 restatements, 8 reduction
rules, catalogue root
`0xdd8947a68c9ca89956a3dd37245426b8e8f84cd0c23668d6c5c7d4b78d18138c`.

The consumer-facing rules — closing events versus restatements, the eight
reduction rules, the root formulas, and the projection algorithm — are normative
in [`docs/v2/event-completeness-projection-replay.md`](../../docs/v2/event-completeness-projection-replay.md).

### Interfaces (v2/interfaces/)

All interfaces in this directory are **CANONICAL V2** and define the protocol's modular architecture:

- `IV2Module.sol` - Base interface for all V2 modules
- `IV2Types.sol` - Common V2 type definitions
- `IEventCompleteness.sol` - Event-completeness record and per-cell coverage
- `IEvidence.sol` - Evidence submission and retrieval
- `IStakeCustody.sol` - Stake custody and settlement
- `IClaims.sol` - Claim registry (implementation pending)
- `IVerification.sol` - Verification workflow (implementation pending)
- `ISettlement.sol` - Settlement logic (implementation pending)
- `IRewards.sol` - Reward distribution (implementation pending)
- `ISlashing.sol` - Slashing logic (implementation pending)
- `IDisputes.sol` - Dispute resolution (implementation pending)
- And others...

### Libraries (v2/libraries/)

| Library | Status | Purpose |
|---------|--------|---------|
| **V2Errors.sol** | ✅ CANONICAL | V2-specific error definitions |
| **V2Lifecycle.sol** | ✅ CANONICAL | Lifecycle state management utilities |
| **V2EventCompleteness.sol** | ✅ CANONICAL | Event-completeness catalogue, reduction rules, roots, and the projection fold (V2-SC-132) |

---

## V2 Design Principles

### 1. Modularity
Each V2 contract is a self-contained module with clear responsibilities. Modules interact through well-defined interfaces.

### 2. Interface-First
All V2 modules implement standardized interfaces (`IV2Module` + specific interface). This enables:
- Independent deployment
- Upgradeable architecture
- Composable protocol features

### 3. Content-Addressed Storage
V2 uses content addressing (hash-based IDs) for deterministic, verifiable data structures.

### 4. Multi-Asset Support
V2 natively supports multiple ERC20 tokens, not just a single protocol token.

### 5. Settlement Lifecycle
V2 implements a formal settlement lifecycle with:
- Lock/unlock semantics
- Appeal mechanisms
- Round-based progression
- Finalization states

---

## V2 vs V1 (Legacy)

| Feature | V1 (Legacy) | V2 (Canonical) |
|---------|-------------|----------------|
| Architecture | Monolithic | Modular |
| Evidence | On-chain or external URL | Content-addressed commitments |
| Staking | Single token | Multi-asset |
| Settlement | Binary pass/fail | Multi-round with appeals |
| Upgradability | Limited | UUPS proxies per module |
| Gas Efficiency | Lower | Higher (optimized) |
| Contract Size | TruthBountyWeighted: 25KB+ | All modules < 24KB |

---

## Deployment Status

| Module | Testnet | Mainnet | Notes |
|--------|---------|---------|-------|
| EvidenceRegistry | ❌ Pending | ❌ Pending | Awaiting V2 baseline approval |
| StakeVault | ❌ Pending | ❌ Pending | Awaiting V2 baseline approval |

---

## Testing

### V2-Specific Test Files

```
test/v2/                         # V2 integration tests
test/EvidenceRegistry.test.ts    # Evidence registry unit tests
test/StakeVault.test.ts          # Stake vault unit tests
test/StakeVault.t.sol            # Stake vault Foundry tests
test/V2Interfaces.test.ts        # Interface conformance tests
test/v2/EventCompleteness.t.sol        # Catalogue completeness, roots, and anchor (V2-SC-132)
test/v2/EventCompletenessManifest.t.sol # Manifest drift against the library (V2-SC-132)
test/v2/ProjectionReplay.t.sol          # Log-only replay of every read cell (V2-SC-132)
test/fuzz/ProjectionReplayFuzz.t.sol     # Replay, R0/R6 reduction, and fold properties (V2-SC-132)
```

### Running V2 Tests

```bash
# Hardhat tests
npx hardhat test test/v2/
npx hardhat test test/EvidenceRegistry.test.ts
npx hardhat test test/StakeVault.test.ts

# Foundry tests
forge test --match-path "test/StakeVault.t.sol"
```

---

## Development Rules

### DO ✅

- Implement `IV2Module` for all new V2 contracts
- Use `V2Types` for common data structures
- Follow content-addressed patterns
- Write comprehensive tests
- Document all public interfaces
- Use OpenZeppelin for standard utilities
- Keep contracts under 24KB

### DON'T ❌

- Add Stellar/Soroban dependencies
- Reference V1 contracts directly
- Deploy without audit approval
- Exceed contract size limits
- Break interface compatibility
- Skip test coverage

---

## Audit Status

**Last Audit:** September 24, 2026  
**Auditor:** Kiro AI Development Environment  
**Report:** `V2_BASELINE_AUDIT_REPORT.md`  

**Findings:**
- ✅ No Stellar/Soroban dependencies
- ✅ Clean modular architecture
- ✅ All contracts compile successfully
- ✅ Well under size limits

**Status:** ✅ APPROVED FOR BASELINE

---

## Next Implementations

The following V2 modules are planned but not yet implemented:

1. **ClaimsRegistry** (IClaims)
2. **VerificationManager** (IVerification)
3. **SettlementEngine** (ISettlement)
4. **RewardDistributor** (IRewards)
5. **SlashingController** (ISlashing)
6. **DisputeResolver** (IDisputes)

See roadmap issues: V2-SC-042, V2-SC-043, V2-SC-044

---

## Contact

For questions about V2 canonical contracts:
- Review this file
- Check `V2_BASELINE_AUDIT_REPORT.md`
- See interface documentation in `interfaces/`
- Review architectural decisions in contract NatSpec

---

**This directory represents the canonical V2 protocol baseline.**  
**All contracts here are approved for production use after external audit.**
