# Security Audit — `routed_stake`

**Revision:** rich lifecycle events, 2026-09-11
**Toolchain:** Sui 1.79.0

## Scope and invariants

A `RoutedStake<StakeShare, PoolShare>` is a derived object of its parent UID
and wraps one `Stake<StakeShare>`. The parent `&mut UID` remains the only
credential for lifecycle operations; there are no sender or supplied-cap-ID
checks in this primitive. `sweep` remains permissionless, but the wrapper
and destination pool must both derive from the supplied parent ID.

The implementation preserves storage, dependency calls, assertion order,
economics, and the original no-op guards. It does not expose the wrapped stake
or invent a parent ID for sharing. The derived stake UID is captured before
unstake destroys it; restake captures the fresh UID. Empty wrappers remain
usable by restake and retain their derived object.

## Event contract

All events are `copy, drop` and phantom-typed by the same dimensions as the
operation:

- created, unstaked, and restaked carry routed-parent-stake addresses and the
  respective value;
- shared carries the wrapper address, presence bit, stake address/value, and
  registration count, with an `@0`/zero empty sentinel;
- registered and unregistered carry observed stake/pool IDs, value, counts,
  pool shares/index, and the relevant registration debt;
- swept carries source/destination IDs, value/parked outcome, principal,
  balances, shares, indices, carries, cumulative deposits, and debt snapshots.

Events are emitted only after the original successful mutation, except that
the shared event is immediately before consuming `self`. Zero-reward and
all pre-claim no-op sweeps remain silent at this wrapper (the dependency may
still emit its own claim event). Unregister captures old debt only when the
registration exists, so a missing registration still reaches the dependency's
`ENotRegistered` abort. Supplied IDs in event payloads are provenance, not
additional authorization.

The fixed BCS sizes are 104 bytes for created/unstaked/restaked, 81 for shared,
232 for registered/unregistered, and 481 for swept.

## Verification

With Sui 1.79.0:

- Testnet and Mainnet lint builds use warnings-as-errors.
- The package test suite has 33 tests (the original 31 plus rich-event schema
  and empty-share sentinel tests); all pass in both environments.
- Coverage runs exercise lifecycle, shared-object production flow, parked and
  deposited sweeps, zero and repeated no-ops, wrong-parent/foreign-pool guard
  precedence, registration failures, fresh restake IDs, generic phantom
  separation, accessors, and fixed-size serialization.
- Production instructions are covered at 100% in each environment.

`Move.toml`, `Move.lock`, and `Published.toml` remain unchanged.
