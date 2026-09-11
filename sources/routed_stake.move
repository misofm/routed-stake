// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A stake whose rewards are irrevocably routed to its parent's royalty pool.
///
/// A `RoutedStake<StakeShare, PoolShare>` is a derived object of any
/// UID-bearing parent (same pattern as `RoyaltyPool`). It wraps a
/// `Stake<StakeShare>` — shares of some other asset that the parent owns —
/// and commits the rewards that stake earns to the parent's own
/// `RoyaltyPool<PoolShare, Currency>`: `sweep` is the only reachable claim
/// path, and it deposits straight into the pool derived from the same parent.
/// The wrapper exists precisely so the raw `Stake` is never exposed — a bare
/// shared `Stake` would let any caller claim its rewards and keep them.
///
/// Because the route is fixed, the wrapper is safe to share: `sweep` is
/// permissionless, and it does not matter who calls it, since the money can
/// only go one place. Lifecycle operations (`register`, `unregister`,
/// `unstake`, `restake`) instead require the parent's `&mut UID` as the
/// credential — cap-gating happens at the parent, exactly as with
/// `RoyaltyPool` creation. `register`/`unregister` are gated because a stake
/// registers at most once per `Currency`: a permissionless register could
/// grief by binding the stake to a garbage same-typed pool, permanently
/// blocking the real one for that currency.
///
/// The derivation key encodes only `StakeShare` — at most one routed stake
/// per `(parent, StakeShare)` pair, whatever `PoolShare` it used (the same
/// burned-by-first-claim consequence as `RoyaltyPoolKey`; the parent's
/// cap-gated extension is expected to pin `PoolShare` to the parent's own
/// share type). For the same reason the wrapper is never deleted: `unstake`
/// empties it and `restake` refills it, so the one derived address per pair
/// stays usable forever.
module routed_stake::routed_stake;

use royalty_pool::pool::RoyaltyPool;
use royalty_pool::stake::{Self, Stake};
use std::type_name;
use sui::balance::Balance;
use sui::derived_object::{claim, derive_address};
use sui::event::emit;

// === Errors ===

const ENotDerivedFromParent: u64 = 0;
const ENoStake: u64 = 1;
const EStakeExists: u64 = 2;

// === Structs ===

public struct RoutedStake<phantom StakeShare, phantom PoolShare> has key {
    id: UID,
    /// The wrapped position. `None` between `unstake` and `restake`; the
    /// wrapper itself persists because its derived address can never be
    /// re-claimed.
    stake: Option<Stake<StakeShare>>,
}

/// Key used to derive a routed stake's object ID from its parent UID.
public struct RoutedStakeKey<phantom StakeShare>() has copy, drop, store;

// === Events ===

public struct RoutedStakeCreatedEvent<phantom StakeShare, phantom PoolShare> has copy, drop {
    routed_stake_id: address,
    parent_id: address,
    stake_id: address,
    staked_value: u64,
}

public struct RoutedStakeSharedEvent<phantom StakeShare, phantom PoolShare> has copy, drop {
    routed_stake_id: address,
    has_stake: bool,
    stake_id: address,
    staked_value: u64,
    registration_count: u64,
}

public struct RoutedStakeRegisteredEvent<phantom StakeShare, phantom PoolShare, phantom Currency> has copy, drop {
    routed_stake_id: address,
    parent_id: address,
    stake_id: address,
    stake_pool_id: address,
    staked_value: u64,
    registration_count_before: u64,
    registration_count_after: u64,
    pool_staked_shares_before: u64,
    pool_staked_shares_after: u64,
    pool_cumulative_reward_per_share: u256,
    registration_debt_after: u256,
}

public struct RoutedStakeUnregisteredEvent<phantom StakeShare, phantom PoolShare, phantom Currency> has copy, drop {
    routed_stake_id: address,
    parent_id: address,
    stake_id: address,
    stake_pool_id: address,
    staked_value: u64,
    registration_count_before: u64,
    registration_count_after: u64,
    pool_staked_shares_before: u64,
    pool_staked_shares_after: u64,
    pool_cumulative_reward_per_share: u256,
    registration_debt_before: u256,
}

public struct RoutedStakeSweptEvent<phantom StakeShare, phantom PoolShare, phantom Currency> has copy, drop {
    routed_stake_id: address,
    parent_id: address,
    stake_id: address,
    stake_pool_id: address,
    routed_pool_id: address,
    value: u64,
    /// `true` when the reward was sent to the routed pool's own address
    /// because it had no stakers to attribute the deposit to; `false` when
    /// it was deposited into the accumulator directly.
    parked: bool,
    staked_value: u64,
    source_balance_before: u64,
    source_balance_after: u64,
    source_staked_shares: u64,
    source_index: u256,
    source_carry: u128,
    source_cumulative_deposits: u128,
    registration_debt_before: u256,
    registration_debt_after: u256,
    destination_balance_before: u64,
    destination_balance_after: u64,
    destination_staked_shares: u64,
    destination_index_before: u256,
    destination_index_after: u256,
    destination_carry_before: u128,
    destination_carry_after: u128,
    destination_cumulative_deposits_before: u128,
    destination_cumulative_deposits_after: u128,
}

public struct RoutedStakeUnstakedEvent<phantom StakeShare, phantom PoolShare> has copy, drop {
    routed_stake_id: address,
    parent_id: address,
    stake_id: address,
    unstaked_value: u64,
}

public struct RoutedStakeRestakedEvent<phantom StakeShare, phantom PoolShare> has copy, drop {
    routed_stake_id: address,
    parent_id: address,
    stake_id: address,
    staked_value: u64,
}

// === Public Functions ===

/// Construct a routed stake as a derived object of `parent`, wrapping
/// `balance` as its staked position. Aborts (in `stake::new`) on a zero
/// balance, and (in `derived_object::claim`) if the `(parent, StakeShare)`
/// address was already claimed.
///
/// Cap-gating happens at the parent: callers must obtain `&mut UID` via
/// whatever cap-gated accessor the parent exposes.
public fun new<StakeShare, PoolShare>(
    parent: &mut UID,
    balance: Balance<StakeShare>,
    ctx: &mut TxContext,
): RoutedStake<StakeShare, PoolShare> {
    let parent_id = parent.to_inner();
    let routed = RoutedStake<StakeShare, PoolShare> {
        id: claim(parent, RoutedStakeKey<StakeShare>()),
        stake: option::some(stake::new(balance, ctx)),
    };
    let stake_id = object::id(routed.stake.borrow()).to_address();

    emit(RoutedStakeCreatedEvent<StakeShare, PoolShare> {
        routed_stake_id: object::id(&routed).to_address(),
        parent_id: parent_id.to_address(),
        stake_id,
        staked_value: routed.value(),
    });

    routed
}

/// Share the routed stake so anyone can `sweep` it.
public fun share<StakeShare, PoolShare>(self: RoutedStake<StakeShare, PoolShare>) {
    let routed_stake_id = object::id(&self).to_address();
    let has_stake = self.stake.is_some();
    let mut stake_id = @0x0;
    let mut staked_value = 0;
    let mut registration_count = 0;
    if (has_stake) {
        let wrapped = self.stake.borrow();
        stake_id = object::id(wrapped).to_address();
        staked_value = wrapped.value();
        registration_count = wrapped.registration_count();
    };
    emit(RoutedStakeSharedEvent<StakeShare, PoolShare> {
        routed_stake_id,
        has_stake,
        stake_id,
        staked_value,
        registration_count,
    });
    transfer::share_object(self);
}

// Lifecycle (parent-gated)

/// Register the wrapped stake with the pool it earns from, so future
/// deposits accrue to it. Which same-typed pool is the *correct* one is the
/// caller's concern — the parent's extension is expected to pin it (e.g. by
/// derivation from the asset object) before delegating here.
public fun register<StakeShare, PoolShare, Currency>(
    self: &mut RoutedStake<StakeShare, PoolShare>,
    parent: &mut UID,
    stake_pool: &mut RoyaltyPool<StakeShare, Currency>,
) {
    self.assert_derived_from(parent.to_inner());
    assert!(self.stake.is_some(), ENoStake);
    let currency = type_name::with_defining_ids<Currency>();
    let routed_stake_id = object::id(self).to_address();
    let parent_id = parent.to_inner().to_address();
    let stake_id = object::id(self.stake.borrow()).to_address();
    let staked_value = self.stake.borrow().value();
    let registration_count_before = self.stake.borrow().registration_count();
    let pool_staked_shares_before = stake_pool.staked_shares();
    stake_pool.register_stake(self.stake.borrow_mut());
    let registration_count_after = self.stake.borrow().registration_count();
    let pool_staked_shares_after = stake_pool.staked_shares();
    let registration = self.stake.borrow().get_registration(&currency);
    let registration_debt_after = stake::registration_debt(registration);
    let pool_cumulative_reward_per_share = stake_pool.cumulative_reward_per_share();
    emit(RoutedStakeRegisteredEvent<StakeShare, PoolShare, Currency> {
        routed_stake_id,
        parent_id,
        stake_id,
        stake_pool_id: object::id(stake_pool).to_address(),
        staked_value,
        registration_count_before,
        registration_count_after,
        pool_staked_shares_before,
        pool_staked_shares_after,
        pool_cumulative_reward_per_share,
        registration_debt_after,
    });
}

/// Unregister the wrapped stake from a pool it earns from. The pool requires
/// claimable rewards to be drained to zero first — i.e. a final `sweep` —
/// so accrued rewards provably reach the parent's pool before the position
/// can move.
public fun unregister<StakeShare, PoolShare, Currency>(
    self: &mut RoutedStake<StakeShare, PoolShare>,
    parent: &mut UID,
    stake_pool: &mut RoyaltyPool<StakeShare, Currency>,
) {
    self.assert_derived_from(parent.to_inner());
    assert!(self.stake.is_some(), ENoStake);
    let currency = type_name::with_defining_ids<Currency>();
    let routed_stake_id = object::id(self).to_address();
    let parent_id = parent.to_inner().to_address();
    let stake_id = object::id(self.stake.borrow()).to_address();
    let staked_value = self.stake.borrow().value();
    let registration_count_before = self.stake.borrow().registration_count();
    let pool_staked_shares_before = stake_pool.staked_shares();
    let mut registration_debt_before = 0;
    if (self.stake.borrow().has_registration(&currency)) {
        registration_debt_before = stake::registration_debt(
            self.stake.borrow().get_registration(&currency),
        );
    };
    stake_pool.unregister_stake(self.stake.borrow_mut());
    let registration_count_after = self.stake.borrow().registration_count();
    let pool_staked_shares_after = stake_pool.staked_shares();
    let pool_cumulative_reward_per_share = stake_pool.cumulative_reward_per_share();
    emit(RoutedStakeUnregisteredEvent<StakeShare, PoolShare, Currency> {
        routed_stake_id,
        parent_id,
        stake_id,
        stake_pool_id: object::id(stake_pool).to_address(),
        staked_value,
        registration_count_before,
        registration_count_after,
        pool_staked_shares_before,
        pool_staked_shares_after,
        pool_cumulative_reward_per_share,
        registration_debt_before,
    });
}

/// Remove the staked position and return its principal. Aborts (in
/// `stake::destroy`) while any pool registrations remain. The emptied
/// wrapper persists — its derived address is burned forever, so deleting it
/// would permanently destroy the parent's ability to route-stake this share
/// type; `restake` refills it instead.
public fun unstake<StakeShare, PoolShare>(
    self: &mut RoutedStake<StakeShare, PoolShare>,
    parent: &mut UID,
): Balance<StakeShare> {
    self.assert_derived_from(parent.to_inner());
    assert!(self.stake.is_some(), ENoStake);
    let stake_id = object::id(self.stake.borrow()).to_address();
    let balance = self.stake.extract().destroy();

    emit(RoutedStakeUnstakedEvent<StakeShare, PoolShare> {
        routed_stake_id: object::id(self).to_address(),
        parent_id: parent.to_inner().to_address(),
        stake_id,
        unstaked_value: balance.value(),
    });

    balance
}

/// Refill an emptied wrapper with a new staked position. Aborts if a
/// position is already present.
public fun restake<StakeShare, PoolShare>(
    self: &mut RoutedStake<StakeShare, PoolShare>,
    parent: &mut UID,
    balance: Balance<StakeShare>,
    ctx: &mut TxContext,
) {
    self.assert_derived_from(parent.to_inner());
    assert!(self.stake.is_none(), EStakeExists);
    self.stake.fill(stake::new(balance, ctx));
    let stake_id = object::id(self.stake.borrow()).to_address();

    emit(RoutedStakeRestakedEvent<StakeShare, PoolShare> {
        routed_stake_id: object::id(self).to_address(),
        parent_id: parent.to_inner().to_address(),
        stake_id,
        staked_value: self.value(),
    });
}

// Sweep (permissionless)

/// Claim the wrapped stake's accrued rewards from `stake_pool` and commit
/// them to `routed_pool` — the parent's own pool. Permissionless: the
/// caller supplies `parent_id`, but cannot lie, because both the wrapper's
/// own address and `routed_pool`'s address must derive from it (checked
/// first, and always — these are wrong-object asserts, not "nothing to
/// do"). Returns the value moved, deposited or parked.
///
/// A crank-facing call never aborts for having nothing to do: `sweep` is a
/// total no-op — 0 returned, no event — in each of these cases, checked in
/// this order before touching either pool: the wrapper is empty
/// (`has_stake` false); the wrapped stake has no registration for
/// `Currency`; or its registration names a pool other than `stake_pool`.
/// Only once all three pass does it claim from `stake_pool` — where a zero
/// reward is, again, a no-op.
///
/// A pool deposit needs a registered stake to attribute to. While
/// `routed_pool` has none, the reward is instead sent to the pool's own
/// address — ordinary address-delivered funds, folded in permissionlessly by
/// `pool::settle` once a stake registers (`parked: true` in the emitted
/// event). Either way the money is committed to the parent's pool, so the
/// route stays fixed and this call — and therefore `unregister`/`unstake` —
/// can never be blocked by the destination's state.
public fun sweep<StakeShare, PoolShare, Currency>(
    self: &mut RoutedStake<StakeShare, PoolShare>,
    stake_pool: &mut RoyaltyPool<StakeShare, Currency>,
    routed_pool: &mut RoyaltyPool<PoolShare, Currency>,
    parent_id: ID,
): u64 {
    self.assert_derived_from(parent_id);
    routed_pool.assert_derived_from(parent_id);

    if (self.stake.is_none()) return 0;

    let currency = type_name::with_defining_ids<Currency>();
    let wrapped = self.stake.borrow();
    if (!wrapped.has_registration(&currency)) return 0;

    let registration = wrapped.get_registration(&currency);
    if (stake::registration_pool_id(registration) != object::id(stake_pool)) return 0;

    let routed_stake_id = object::id(self).to_address();
    let parent_address = parent_id.to_address();
    let stake_id = object::id(wrapped).to_address();
    let staked_value = wrapped.value();
    let stake_pool_id = object::id(stake_pool).to_address();
    let routed_pool_id = object::id(routed_pool).to_address();
    let registration_debt_before = stake::registration_debt(registration);
    let source_balance_before = stake_pool.balance().value();
    let source_staked_shares = stake_pool.staked_shares();
    let source_index = stake_pool.cumulative_reward_per_share();
    let source_carry = stake_pool.carry();
    let source_cumulative_deposits = stake_pool.cumulative_deposits();
    let destination_balance_before = routed_pool.balance().value();
    let destination_staked_shares = routed_pool.staked_shares();
    let destination_index_before = routed_pool.cumulative_reward_per_share();
    let destination_carry_before = routed_pool.carry();
    let destination_cumulative_deposits_before = routed_pool.cumulative_deposits();
    let reward = stake_pool.claim_rewards(self.stake.borrow_mut());
    let value = reward.value();
    if (value == 0) {
        reward.destroy_zero();
        return 0
    };

    let parked = routed_pool.staked_shares() == 0;
    if (parked) {
        reward.send_funds(object::id(routed_pool).to_address());
    } else {
        routed_pool.deposit(reward);
    };

    let registration_debt_after = stake::registration_debt(
        self.stake.borrow().get_registration(&currency),
    );
    let source_balance_after = stake_pool.balance().value();
    let destination_balance_after = routed_pool.balance().value();
    let destination_index_after = routed_pool.cumulative_reward_per_share();
    let destination_carry_after = routed_pool.carry();
    let destination_cumulative_deposits_after = routed_pool.cumulative_deposits();
    emit(RoutedStakeSweptEvent<StakeShare, PoolShare, Currency> {
        routed_stake_id,
        parent_id: parent_address,
        stake_id,
        stake_pool_id,
        routed_pool_id,
        value,
        parked,
        staked_value,
        source_balance_before,
        source_balance_after,
        source_staked_shares,
        source_index,
        source_carry,
        source_cumulative_deposits,
        registration_debt_before,
        registration_debt_after,
        destination_balance_before,
        destination_balance_after,
        destination_staked_shares,
        destination_index_before,
        destination_index_after,
        destination_carry_before,
        destination_carry_after,
        destination_cumulative_deposits_before,
        destination_cumulative_deposits_after,
    });

    value
}

// === View Functions ===

public fun has_stake<StakeShare, PoolShare>(self: &RoutedStake<StakeShare, PoolShare>): bool {
    self.stake.is_some()
}

/// Staked principal, or 0 while the wrapper is empty.
public fun value<StakeShare, PoolShare>(self: &RoutedStake<StakeShare, PoolShare>): u64 {
    if (self.stake.is_some()) self.stake.borrow().value() else 0
}

/// Read-only access to the wrapped stake, e.g. for `pool::pending_rewards`.
/// Aborts while the wrapper is empty (`has_stake` to guard).
public fun stake<StakeShare, PoolShare>(
    self: &RoutedStake<StakeShare, PoolShare>,
): &Stake<StakeShare> {
    assert!(self.stake.is_some(), ENoStake);
    self.stake.borrow()
}

/// Compute the deterministic address of a routed stake given its parent ID
/// and `StakeShare` type parameter.
public fun derived_address<StakeShare>(parent_id: ID): address {
    derive_address(parent_id, RoutedStakeKey<StakeShare>())
}

/// Verify the routed stake was derived from the given parent ID.
public fun assert_derived_from<StakeShare, PoolShare>(
    self: &RoutedStake<StakeShare, PoolShare>,
    parent_id: ID,
) {
    assert!(
        self.id.to_address() == derive_address(parent_id, RoutedStakeKey<StakeShare>()),
        ENotDerivedFromParent,
    );
}

// === Test Functions ===

/// Test-only accessor for `RoutedStakeSweptEvent`'s payload — the struct's
/// fields are module-private and the event carries no other public reader.
#[test_only]
public fun swept_event_fields<StakeShare, PoolShare, Currency>(
    event: &RoutedStakeSweptEvent<StakeShare, PoolShare, Currency>,
): (address, address, address, address, address, u64, bool, u64, u64, u64, u64, u256, u128, u128, u256, u256, u64, u64, u64, u256, u256, u128, u128, u128, u128) {
    (
        event.routed_stake_id,
        event.parent_id,
        event.stake_id,
        event.stake_pool_id,
        event.routed_pool_id,
        event.value,
        event.parked,
        event.staked_value,
        event.source_balance_before,
        event.source_balance_after,
        event.source_staked_shares,
        event.source_index,
        event.source_carry,
        event.source_cumulative_deposits,
        event.registration_debt_before,
        event.registration_debt_after,
        event.destination_balance_before,
        event.destination_balance_after,
        event.destination_staked_shares,
        event.destination_index_before,
        event.destination_index_after,
        event.destination_carry_before,
        event.destination_carry_after,
        event.destination_cumulative_deposits_before,
        event.destination_cumulative_deposits_after,
    )
}

/// Compatibility summary for tests that only need the event's routing and
/// transfer outcome; `swept_event_fields` above exposes the complete payload.
#[test_only]
public fun swept_event_summary<StakeShare, PoolShare, Currency>(
    event: &RoutedStakeSweptEvent<StakeShare, PoolShare, Currency>,
): (address, address, u64, bool) {
    (event.routed_stake_id, event.parent_id, event.value, event.parked)
}

/// Test-only accessor for `RoutedStakeUnstakedEvent`'s payload.
#[test_only]
public fun unstaked_event_fields<StakeShare, PoolShare>(
    event: &RoutedStakeUnstakedEvent<StakeShare, PoolShare>,
): (address, address, address, u64) {
    (event.routed_stake_id, event.parent_id, event.stake_id, event.unstaked_value)
}

#[test_only]
public fun created_event_fields<StakeShare, PoolShare>(
    event: &RoutedStakeCreatedEvent<StakeShare, PoolShare>,
): (address, address, address, u64) {
    (event.routed_stake_id, event.parent_id, event.stake_id, event.staked_value)
}

#[test_only]
public fun shared_event_fields<StakeShare, PoolShare>(
    event: &RoutedStakeSharedEvent<StakeShare, PoolShare>,
): (address, bool, address, u64, u64) {
    (
        event.routed_stake_id,
        event.has_stake,
        event.stake_id,
        event.staked_value,
        event.registration_count,
    )
}

#[test_only]
public fun registered_event_fields<StakeShare, PoolShare, Currency>(
    event: &RoutedStakeRegisteredEvent<StakeShare, PoolShare, Currency>,
): (address, address, address, address, u64, u64, u64, u64, u64, u256, u256) {
    (
        event.routed_stake_id,
        event.parent_id,
        event.stake_id,
        event.stake_pool_id,
        event.staked_value,
        event.registration_count_before,
        event.registration_count_after,
        event.pool_staked_shares_before,
        event.pool_staked_shares_after,
        event.pool_cumulative_reward_per_share,
        event.registration_debt_after,
    )
}

#[test_only]
public fun unregistered_event_fields<StakeShare, PoolShare, Currency>(
    event: &RoutedStakeUnregisteredEvent<StakeShare, PoolShare, Currency>,
): (address, address, address, address, u64, u64, u64, u64, u64, u256, u256) {
    (
        event.routed_stake_id,
        event.parent_id,
        event.stake_id,
        event.stake_pool_id,
        event.staked_value,
        event.registration_count_before,
        event.registration_count_after,
        event.pool_staked_shares_before,
        event.pool_staked_shares_after,
        event.pool_cumulative_reward_per_share,
        event.registration_debt_before,
    )
}

#[test_only]
public fun restaked_event_fields<StakeShare, PoolShare>(
    event: &RoutedStakeRestakedEvent<StakeShare, PoolShare>,
): (address, address, address, u64) {
    (event.routed_stake_id, event.parent_id, event.stake_id, event.staked_value)
}
