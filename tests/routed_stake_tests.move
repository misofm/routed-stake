// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit-style coverage for `routed_stake`'s pure abort/logic paths: wrong
/// `&mut UID` credential, wrong-typed/foreign pool, double-claim of a derived
/// address, the `EStakeExists` lifecycle state error, and `sweep`'s total
/// no-op cases (no stake, no registration for `Currency`, a registration
/// naming a different pool, a zero reward). None of these gate on *sender* —
/// `routed_stake` has no capability object of its own, only object-identity
/// checks against the `&mut UID` a caller happens to hold — so a
/// single-transaction `tx_context::dummy()` proves them just as faithfully
/// as a multi-actor scenario would. `ENoStake` (the intents `register` /
/// `unregister` / `unstake` still abort on an empty wrapper) and the
/// genuinely ownership-shaped flows (shared objects, `take_shared`, the
/// permissionless `sweep` by a stranger sender) live in
/// `routed_stake_e2e_tests`.
#[test_only]
module routed_stake::routed_stake_tests;

use routed_stake::routed_stake::{Self, RoutedStake};
use royalty_pool::pool::{Self, RoyaltyPool};
use royalty_pool::stake;
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::event;

// Mirrored from royalty_pool::pool (private there).
const EPoolNotDerivedFromParent: u64 = 0;
const EAlreadyRegistered: u64 = 2;
const ENotRegistered: u64 = 3;
const EPoolIdMismatch: u64 = 4;
const ELastClaimIndexMismatch: u64 = 5;
// Mirrored from royalty_pool::stake (private there).
const EZeroBalance: u64 = 0;
const EPoolsRegistered: u64 = 1;

// Phantom marker types for the share/currency parameters.
public struct ASSET_SHARE {}
public struct PARENT_SHARE {}
public struct USD {}

/// The real topology in miniature: the pool the routed stake earns from
/// (`stake_pool`) is derived from the ASSET object (e.g. a recording), while
/// the pool rewards are routed to (`routed_pool`) is derived from the PARENT
/// (e.g. a composition) — the same parent the routed stake derives from.
fun setup(
    ctx: &mut TxContext,
): (UID, UID, RoyaltyPool<ASSET_SHARE, USD>, RoyaltyPool<PARENT_SHARE, USD>) {
    let mut asset = object::new(ctx);
    let mut parent = object::new(ctx);
    let stake_pool = pool::new<ASSET_SHARE, USD>(&mut asset);
    let routed_pool = pool::new<PARENT_SHARE, USD>(&mut parent);
    (asset, parent, stake_pool, routed_pool)
}

#[test]
fun sweep_routes_rewards_to_the_parent_pool() {
    let ctx = &mut tx_context::dummy();
    let (asset, mut parent, mut stake_pool, mut routed_pool) = setup(ctx);
    let parent_id = parent.to_inner();

    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );
    assert_eq!(object::id(&routed).to_address(), routed_stake::derived_address<ASSET_SHARE>(parent_id));
    routed.register(&mut parent, &mut stake_pool);

    // The routed stake is the sole staker in the stake pool, so it earns the
    // full deposit. A holder registers in the parent's pool so the swept
    // deposit is attributable.
    stake_pool.deposit(balance::create_for_testing<USD>(500));
    let mut holder = stake::new(balance::create_for_testing<PARENT_SHARE>(100), ctx);
    routed_pool.register_stake(&mut holder);

    let value = routed.sweep(&mut stake_pool, &mut routed_pool, parent_id);
    assert_eq!(value, 500);

    // The reward never surfaced as a free balance: it sits in the parent's
    // pool, claimable by the registered holder in full.
    assert_eq!(routed_pool.balance().value(), 500);
    let holder_reward = routed_pool.claim_rewards(&mut holder);
    assert_eq!(holder_reward.value(), 500);

    // A zero-reward sweep is a total no-op — no deposit, no event, 0 returned.
    let value = routed.sweep(&mut stake_pool, &mut routed_pool, parent_id);
    assert_eq!(value, 0);
    let swept = event::events_by_type<
        routed_stake::RoutedStakeSweptEvent<ASSET_SHARE, PARENT_SHARE, USD>,
    >();
    assert_eq!(swept.length(), 1);

    destroy(holder_reward);
    destroy(holder);
    destroy(routed);
    destroy(stake_pool);
    destroy(routed_pool);
    asset.delete();
    parent.delete();
}

#[test]
fun lifecycle_unstake_round_trips_and_restake_refills() {
    let ctx = &mut tx_context::dummy();
    let (asset, mut parent, mut stake_pool, routed_pool) = setup(ctx);

    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );
    routed.register(&mut parent, &mut stake_pool);

    // Nothing accrued → unregister needs no sweep; principal round-trips.
    routed.unregister(&mut parent, &mut stake_pool);
    let principal = routed.unstake(&mut parent);
    assert_eq!(principal.value(), 1000);
    assert!(!routed.has_stake());
    assert_eq!(routed.value(), 0);

    // The emptied wrapper persists (its derived address is burned forever)
    // and can be refilled.
    routed.restake(&mut parent, balance::create_for_testing<ASSET_SHARE>(700), ctx);
    assert_eq!(routed.value(), 700);
    routed.register(&mut parent, &mut stake_pool);

    destroy(principal);
    destroy(routed);
    destroy(stake_pool);
    destroy(routed_pool);
    asset.delete();
    parent.delete();
}

#[test, expected_failure(abort_code = routed_stake::ENotDerivedFromParent, location = routed_stake)]
fun sweep_rejects_wrong_parent_id() {
    let ctx = &mut tx_context::dummy();
    let (asset, mut parent, mut stake_pool, mut routed_pool) = setup(ctx);

    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );

    // A forged parent id fails the wrapper's own derivation check.
    routed.sweep(&mut stake_pool, &mut routed_pool, asset.to_inner());
    abort
}

#[test, expected_failure(abort_code = EPoolNotDerivedFromParent, location = royalty_pool::pool)]
fun sweep_rejects_foreign_routed_pool() {
    let ctx = &mut tx_context::dummy();
    let (_asset, mut parent, mut stake_pool, _routed_pool) = setup(ctx);
    let parent_id = parent.to_inner();
    // An attacker's same-typed pool, derived from a parent they control.
    let mut attacker_parent = object::new(ctx);
    let mut attacker_pool = pool::new<PARENT_SHARE, USD>(&mut attacker_parent);

    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );

    // The type checks pass; the destination's derivation does not.
    routed.sweep(&mut stake_pool, &mut attacker_pool, parent_id);
    abort
}

/// The two wrong-object asserts run before guard (i) (`self.stake.is_none()`),
/// not after: an emptied wrapper — which would otherwise take the total
/// no-op path — must still abort on a forged `parent_id`, proving the
/// asserts are not short-circuited by the no-op checks.
#[test, expected_failure(abort_code = routed_stake::ENotDerivedFromParent, location = routed_stake)]
fun sweep_asserts_derivation_before_the_no_stake_guard() {
    let ctx = &mut tx_context::dummy();
    let (asset, mut parent, mut stake_pool, mut routed_pool) = setup(ctx);

    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );
    destroy(routed.unstake(&mut parent));

    // The wrapper is empty — guard (i) would return 0 — but a forged parent
    // id must abort before that guard is ever reached.
    routed.sweep(&mut stake_pool, &mut routed_pool, asset.to_inner());
    abort
}

/// Same ordering claim for `routed_pool`'s own derivation assert: an emptied
/// wrapper does not let a foreign routed pool slip through as a no-op.
#[test, expected_failure(abort_code = EPoolNotDerivedFromParent, location = royalty_pool::pool)]
fun sweep_asserts_routed_pool_derivation_before_the_no_stake_guard() {
    let ctx = &mut tx_context::dummy();
    let (_asset, mut parent, mut stake_pool, _routed_pool) = setup(ctx);
    let parent_id = parent.to_inner();
    let mut foreign_parent = object::new(ctx);
    let mut foreign_pool = pool::new<PARENT_SHARE, USD>(&mut foreign_parent);

    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );
    destroy(routed.unstake(&mut parent));

    routed.sweep(&mut stake_pool, &mut foreign_pool, parent_id);
    abort
}

#[test, expected_failure(abort_code = routed_stake::ENotDerivedFromParent, location = routed_stake)]
fun register_rejects_wrong_parent_credential() {
    let ctx = &mut tx_context::dummy();
    let (mut asset, mut parent, mut stake_pool, _routed_pool) = setup(ctx);

    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );

    // Control of some other UID is not authority over this wrapper.
    routed.register(&mut asset, &mut stake_pool);
    abort
}

#[test, expected_failure(abort_code = routed_stake::ENotDerivedFromParent, location = routed_stake)]
fun unstake_rejects_wrong_parent_credential() {
    let ctx = &mut tx_context::dummy();
    let (mut asset, mut parent, _stake_pool, _routed_pool) = setup(ctx);

    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );

    let _principal = routed.unstake(&mut asset);
    abort
}

#[test, expected_failure(abort_code = routed_stake::ENotDerivedFromParent, location = routed_stake)]
fun unregister_rejects_wrong_parent_credential() {
    let ctx = &mut tx_context::dummy();
    let (mut asset, mut parent, mut stake_pool, _routed_pool) = setup(ctx);

    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );

    // Control of some other UID is not authority over this wrapper.
    routed.unregister(&mut asset, &mut stake_pool);
    abort
}

// `register_stake`'s and `unregister_stake`'s own invariants are one call
// deep inside `routed_stake::register`/`unregister`; reached here through
// this module's public API exactly as a caller of it would trigger them.

#[test, expected_failure(abort_code = EAlreadyRegistered, location = royalty_pool::pool)]
fun register_twice_for_the_same_currency_aborts() {
    let ctx = &mut tx_context::dummy();
    let (_asset, mut parent, mut stake_pool, _routed_pool) = setup(ctx);

    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );
    routed.register(&mut parent, &mut stake_pool);

    // Already registered for this Currency.
    routed.register(&mut parent, &mut stake_pool);
    abort
}

#[test, expected_failure(abort_code = ENotRegistered, location = royalty_pool::pool)]
fun unregister_never_registered_aborts() {
    let ctx = &mut tx_context::dummy();
    let (_asset, mut parent, mut stake_pool, _routed_pool) = setup(ctx);

    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );

    // Never registered — nothing for the pool to unregister.
    routed.unregister(&mut parent, &mut stake_pool);
    abort
}

#[test, expected_failure(abort_code = EPoolIdMismatch, location = royalty_pool::pool)]
fun unregister_against_a_different_pool_aborts() {
    let ctx = &mut tx_context::dummy();
    let (_asset_x, mut parent, mut stake_pool_x, _routed_pool) = setup(ctx);
    let mut asset_y = object::new(ctx);
    let mut stake_pool_y = pool::new<ASSET_SHARE, USD>(&mut asset_y);

    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );
    // Registered with pool X ...
    routed.register(&mut parent, &mut stake_pool_x);

    // ... but unregistered against pool Y, a different (same-typed) pool.
    routed.unregister(&mut parent, &mut stake_pool_y);
    abort
}

#[test, expected_failure(abort_code = ELastClaimIndexMismatch, location = royalty_pool::pool)]
fun unregister_with_pending_rewards_aborts() {
    let ctx = &mut tx_context::dummy();
    let (_asset, mut parent, mut stake_pool, _routed_pool) = setup(ctx);

    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );
    routed.register(&mut parent, &mut stake_pool);
    stake_pool.deposit(balance::create_for_testing<USD>(500));

    // A final sweep is required first — unregister with rewards still
    // claimable aborts rather than stranding them.
    routed.unregister(&mut parent, &mut stake_pool);
    abort
}

#[test, expected_failure(abort_code = EPoolsRegistered, location = royalty_pool::stake)]
fun unstake_while_registered_aborts() {
    let ctx = &mut tx_context::dummy();
    let (_asset, mut parent, mut stake_pool, _routed_pool) = setup(ctx);

    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );
    routed.register(&mut parent, &mut stake_pool);

    // Still registered → stake::destroy aborts EPoolsRegistered.
    let _principal = routed.unstake(&mut parent);
    abort
}

/// `sweep` on an emptied wrapper is a total no-op: 0 returned, no event —
/// not the `ENoStake` abort the pre-total API used. `unregister`/`unstake`
/// are the intents that still abort `ENoStake`; `sweep` never does.
#[test]
fun sweep_on_emptied_wrapper_is_a_total_no_op() {
    let ctx = &mut tx_context::dummy();
    let (asset, mut parent, mut stake_pool, mut routed_pool) = setup(ctx);
    let parent_id = parent.to_inner();

    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );
    destroy(routed.unstake(&mut parent));

    let value = routed.sweep(&mut stake_pool, &mut routed_pool, parent_id);
    assert_eq!(value, 0);
    let swept = event::events_by_type<
        routed_stake::RoutedStakeSweptEvent<ASSET_SHARE, PARENT_SHARE, USD>,
    >();
    assert_eq!(swept.length(), 0);

    destroy(routed);
    destroy(stake_pool);
    destroy(routed_pool);
    asset.delete();
    parent.delete();
}

/// A wrapped stake that was never registered for `Currency` has nothing to
/// claim from — checked (and stopped) before `sweep` ever touches either
/// pool.
#[test]
fun sweep_on_unregistered_position_is_a_total_no_op() {
    let ctx = &mut tx_context::dummy();
    let (asset, mut parent, mut stake_pool, mut routed_pool) = setup(ctx);
    let parent_id = parent.to_inner();

    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );

    let value = routed.sweep(&mut stake_pool, &mut routed_pool, parent_id);
    assert_eq!(value, 0);
    let swept = event::events_by_type<
        routed_stake::RoutedStakeSweptEvent<ASSET_SHARE, PARENT_SHARE, USD>,
    >();
    assert_eq!(swept.length(), 0);

    destroy(routed);
    destroy(stake_pool);
    destroy(routed_pool);
    asset.delete();
    parent.delete();
}

/// Once `unregister` removes the `Currency` registration, a further `sweep`
/// is a no-op again — the same guard that stopped the never-registered case
/// above, now stopping a formerly-registered one.
#[test]
fun sweep_after_unregister_is_a_total_no_op() {
    let ctx = &mut tx_context::dummy();
    let (asset, mut parent, mut stake_pool, mut routed_pool) = setup(ctx);
    let parent_id = parent.to_inner();

    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );
    routed.register(&mut parent, &mut stake_pool);
    routed.unregister(&mut parent, &mut stake_pool);

    let value = routed.sweep(&mut stake_pool, &mut routed_pool, parent_id);
    assert_eq!(value, 0);
    let swept = event::events_by_type<
        routed_stake::RoutedStakeSweptEvent<ASSET_SHARE, PARENT_SHARE, USD>,
    >();
    assert_eq!(swept.length(), 0);

    destroy(routed);
    destroy(stake_pool);
    destroy(routed_pool);
    asset.delete();
    parent.delete();
}

/// A registration names a specific pool by ID. Sweeping against a
/// same-typed, same-currency pool the stake is *not* registered with is a
/// no-op, without ever needing (or violating) a derivation assert on
/// `stake_pool` — `sweep` only asserts derivation for `self` and
/// `routed_pool`.
#[test]
fun sweep_against_a_different_pool_of_the_same_currency_is_a_total_no_op() {
    let ctx = &mut tx_context::dummy();
    let (asset_x, mut parent, mut stake_pool_x, mut routed_pool) = setup(ctx);
    let parent_id = parent.to_inner();
    let mut asset_y = object::new(ctx);
    let mut stake_pool_y = pool::new<ASSET_SHARE, USD>(&mut asset_y);

    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );
    // Registered with pool X ...
    routed.register(&mut parent, &mut stake_pool_x);

    // ... but swept against pool Y, a different (same-typed) pool.
    let value = routed.sweep(&mut stake_pool_y, &mut routed_pool, parent_id);
    assert_eq!(value, 0);
    let swept = event::events_by_type<
        routed_stake::RoutedStakeSweptEvent<ASSET_SHARE, PARENT_SHARE, USD>,
    >();
    assert_eq!(swept.length(), 0);

    routed.unregister(&mut parent, &mut stake_pool_x);
    destroy(routed.unstake(&mut parent));
    destroy(routed);
    destroy(stake_pool_x);
    destroy(stake_pool_y);
    destroy(routed_pool);
    asset_x.delete();
    asset_y.delete();
    parent.delete();
}

#[test, expected_failure(abort_code = routed_stake::EStakeExists, location = routed_stake)]
fun restake_while_stake_exists_aborts() {
    let ctx = &mut tx_context::dummy();
    let (_asset, mut parent, _stake_pool, _routed_pool) = setup(ctx);

    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );

    routed.restake(&mut parent, balance::create_for_testing<ASSET_SHARE>(1), ctx);
    abort
}

#[test, expected_failure(abort_code = routed_stake::ENotDerivedFromParent, location = routed_stake)]
fun restake_rejects_wrong_parent_credential() {
    let ctx = &mut tx_context::dummy();
    let (mut asset, mut parent, _stake_pool, _routed_pool) = setup(ctx);

    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );

    // Control of some other UID is not authority over this wrapper.
    routed.restake(&mut asset, balance::create_for_testing<ASSET_SHARE>(1), ctx);
    abort
}

// `restake` wraps `balance` into `stake::new` exactly as `new` does, so a
// zero balance aborts there too (`EZeroBalance`), before a stake is ever
// installed into the emptied wrapper.
#[test, expected_failure(abort_code = EZeroBalance, location = royalty_pool::stake)]
fun restake_with_zero_balance_aborts() {
    let ctx = &mut tx_context::dummy();
    let (_asset, mut parent, _stake_pool, _routed_pool) = setup(ctx);

    let mut routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );
    destroy(routed.unstake(&mut parent));

    routed.restake(&mut parent, balance::create_for_testing<ASSET_SHARE>(0), ctx);
    abort
}

// `new` wraps `balance` straight into `stake::new`, so a zero balance aborts
// there (`EZeroBalance`) before a `RoutedStake` is ever constructed.
#[test, expected_failure(abort_code = EZeroBalance, location = royalty_pool::stake)]
fun new_with_zero_balance_aborts() {
    let ctx = &mut tx_context::dummy();
    let (_asset, mut parent, _stake_pool, _routed_pool) = setup(ctx);

    let _routed = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(0),
        ctx,
    );
    abort
}

// Claiming the same (parent, StakeShare) derived address twice aborts inside
// the framework's `derived_object::claim` — the burned-address property the
// module doc relies on.
#[test, expected_failure]
fun new_twice_for_same_parent_and_share_aborts() {
    let ctx = &mut tx_context::dummy();
    let (_asset, mut parent, _stake_pool, _routed_pool) = setup(ctx);

    let _routed_a = routed_stake::new<ASSET_SHARE, PARENT_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );
    // Even a different PoolShare phantom cannot re-claim the address: the key
    // encodes only StakeShare.
    let _routed_b = routed_stake::new<ASSET_SHARE, ASSET_SHARE>(
        &mut parent,
        balance::create_for_testing<ASSET_SHARE>(1000),
        ctx,
    );
    abort
}
