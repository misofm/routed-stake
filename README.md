# `routed_stake`

> A stake whose rewards are irrevocably routed to its parent's royalty pool. The shared primitive behind trustless "entity earns on shares it owns" custody (`composition_routed_stake`).

**Layer:** `lib` — a primitive, not core protocol and not an extension (it attaches to nothing miso-specific). Like `royalty_pool`, it is parent-agnostic: a `RoutedStake<StakeShare, PoolShare>` is a derived object of any UID-bearing parent.

A `RoutedStake` wraps a `royalty_pool::stake::Stake<StakeShare>` — shares of some other asset that the parent owns — and commits the rewards that stake earns to the parent's own `RoyaltyPool<PoolShare, Currency>`. The wrapper exists precisely so the raw `Stake` is never exposed: a bare shared `Stake` would let any caller claim its rewards and keep them. Because the route is fixed, the wrapper is safe to share — `sweep` is permissionless, and it does not matter who calls it, since the money can only go one place.

`sweep`'s destination cannot be forged: the caller supplies the parent id, but both the wrapper's own address and the destination pool's address must derive from it (`derived_object` addresses are deterministic and collision-resistant), so a same-typed pool parented anywhere else is rejected.

Lifecycle operations take the parent's `&mut UID` as the credential — cap-gating happens at the parent, exactly as with `RoyaltyPool` creation. `register`/`unregister` are gated because a stake registers at most once per `Currency`: a permissionless register could grief by binding the stake to a garbage same-typed pool. The wrapper is never deleted: its derived address is burned forever at claim, so `unstake` empties it and `restake` refills it.

## API

- **`routed_stake::new<StakeShare, PoolShare>(parent, balance, ctx)`** — claims the derived object and wraps `balance` as the staked position; `share` makes it publicly sweepable.
- **`routed_stake::register` / `unregister`** — parent-gated; binds/unbinds the position to the pool it earns from. Unregister requires rewards drained to zero (a final `sweep`) first.
- **`routed_stake::sweep<StakeShare, PoolShare, Currency>(stake_pool, routed_pool, parent_id): u64`** — permissionless; claims accrued rewards and commits them to the parent's pool. Returns the value moved. Total: a crank-facing call never aborts for having nothing to do — it is a no-op returning 0, with no wrapper event, when the wrapper is empty, when the wrapped stake has no registration for `Currency`, when that registration names a pool other than `stake_pool`, or when the claimed reward is zero. Otherwise it emits a `RoutedStakeSweptEvent` containing the routed/stake/pool addresses, transfer outcome, source and destination balances, shares, indices, carries, cumulative deposits, and registration debt before/after mutation. While the parent's pool has no registered stake, the reward is sent to the pool's own address (`parked: true`); once the pool has stakers it is deposited directly (`parked: false`).
- **`routed_stake::unstake` / `restake`** — parent-gated; removes the position and returns its principal `Balance` / refills the emptied wrapper.
- **`routed_stake::derived_address<StakeShare>(parent_id)`** — the wrapper's deterministic address; `assert_derived_from` verifies it on-chain.
- Views: `has_stake`, `value`, `stake` (read-only, e.g. for `pool::pending_rewards`),
  `derived_address`, and `assert_derived_from`.

Every lifecycle transition has one phantom-typed event: `RoutedStakeCreatedEvent`,
`RoutedStakeSharedEvent`, `RoutedStakeRegisteredEvent`,
`RoutedStakeUnregisteredEvent`, `RoutedStakeSweptEvent`,
`RoutedStakeUnstakedEvent`, and `RoutedStakeRestakedEvent`. IDs are encoded as
addresses for stable event consumers. Created/unstaked/restaked payloads are
104-byte BCS values, shared is 81 bytes, registered/unregistered are 232 bytes,
and swept is 481 bytes. `share` emits immediately before consuming the wrapper;
an empty sentinel uses `has_stake: false`, `stake_id: @0`, and zero values.

## Dependencies

- **`royalty_pool`** — `stake::Stake` (the wrapped position) and `pool::RoyaltyPool` (both the source and destination of `sweep`). Public API only; no package-private coupling.

## Build & test

```sh
sui move build --lint --warnings-are-errors --build-env testnet
sui move test --build-env testnet --coverage
sui move coverage summary --summarize-functions
sui move build --lint --warnings-are-errors --build-env mainnet
sui move test --build-env mainnet --coverage
```
