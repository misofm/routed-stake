// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// `register`'s `ESelfRoute` guard: the parent's own
/// `RoyaltyPool<PoolShare, Currency>` is `sweep`'s destination, so binding
/// the wrapped stake to earn from that same object would make `sweep`
/// unconstructible (one shared object cannot be both of its `&mut` pool
/// arguments) and, after the first deposit, `unregister` and `unstake`
/// would abort forever — a permanent lock of the principal.
///
/// The guard is an object-identity (address) check, not a type check, so
/// this module proves both halves: every shape that is that one object is
/// refused (even after a `restake`, even for a second currency next to a
/// legitimate first registration), and every shape that merely *looks*
/// similar — the same share type staked under a different parent, or a
/// stake pool that is also derived from the parent but under a different
/// share type — registers, sweeps, unregisters and unstakes normally.
#[test_only]
module routed_stake::routed_stake_self_route_tests;

use routed_stake::routed_stake;
use royalty_pool::pool;
use royalty_pool::stake;
use std::unit_test::{assert_eq, destroy};
use sui::balance;

// Phantom marker types for the share/currency parameters.
public struct SHARE {}
public struct OTHER_SHARE {}
public struct RECORDING_SHARE {}
public struct COMPOSITION_SHARE {}
public struct USD {}
public struct EUR {}

// === Must abort: the stake pool IS the parent's destination pool ===

/// Scenario 1: `RoutedStake<S, S>` under `P`, registered into `P`'s own
/// `RoyaltyPool<S, C>` — the exact lock shape from the audit.
#[test, expected_failure(abort_code = routed_stake::ESelfRoute, location = routed_stake)]
fun register_rejects_the_parents_own_pool() {
    let ctx = &mut tx_context::dummy();
    let mut parent = object::new(ctx);
    let mut own_pool = pool::new_for_testing<SHARE, USD>(&mut parent);
    // Sanity: this is the pool `sweep` would demand as `routed_pool`.
    assert_eq!(
        object::id(&own_pool).to_address(),
        pool::derived_address<SHARE, USD>(parent.to_inner()),
    );

    let mut routed = routed_stake::new<SHARE, SHARE>(
        &mut parent,
        balance::create_for_testing<SHARE>(1000),
        ctx,
    );

    routed.register(&mut parent, &mut own_pool);
    abort
}

/// Scenario 2: the refilled wrapper cannot be self-registered either — the
/// guard reads the wrapper's *current* parent/type identity, not any state
/// from the first staking.
#[test, expected_failure(abort_code = routed_stake::ESelfRoute, location = routed_stake)]
fun register_rejects_the_parents_own_pool_after_restake() {
    let ctx = &mut tx_context::dummy();
    let mut parent = object::new(ctx);
    let mut own_pool = pool::new_for_testing<SHARE, USD>(&mut parent);

    let mut routed = routed_stake::new<SHARE, SHARE>(
        &mut parent,
        balance::create_for_testing<SHARE>(1000),
        ctx,
    );
    // Never registered, so the exit is open: empty and refill the wrapper.
    destroy(routed.unstake(&mut parent));
    assert!(!routed.has_stake());
    routed.restake(&mut parent, balance::create_for_testing<SHARE>(700), ctx);
    assert_eq!(routed.value(), 700);

    routed.register(&mut parent, &mut own_pool);
    abort
}

/// Scenario 3: a legitimate registration for `USD` (a same-typed pool under
/// a different parent) does not open the door to a self-route for `EUR`.
/// Registrations are per-currency, and so is the guard.
#[test, expected_failure(abort_code = routed_stake::ESelfRoute, location = routed_stake)]
fun register_rejects_the_parents_own_pool_for_a_second_currency() {
    let ctx = &mut tx_context::dummy();
    let mut parent = object::new(ctx);
    let mut other_parent = object::new(ctx);
    let mut foreign_usd_pool = pool::new_for_testing<SHARE, USD>(&mut other_parent);
    let mut own_eur_pool = pool::new_for_testing<SHARE, EUR>(&mut parent);

    let mut routed = routed_stake::new<SHARE, SHARE>(
        &mut parent,
        balance::create_for_testing<SHARE>(1000),
        ctx,
    );
    // Legitimate: same share type, different parent.
    routed.register(&mut parent, &mut foreign_usd_pool);
    assert_eq!(routed.stake().registration_count(), 1);

    // Self-route for the second currency: refused.
    routed.register(&mut parent, &mut own_eur_pool);
    abort
}

// === Guard ordering: the existing checks still run first ===

/// The credential check precedes the self-route check: a caller holding
/// the wrong `&mut UID` gets `ENotDerivedFromParent`, never `ESelfRoute`.
#[test, expected_failure(abort_code = routed_stake::ENotDerivedFromParent, location = routed_stake)]
fun self_route_check_runs_after_the_credential_check() {
    let ctx = &mut tx_context::dummy();
    let mut parent = object::new(ctx);
    let mut other = object::new(ctx);
    let mut own_pool = pool::new_for_testing<SHARE, USD>(&mut parent);

    let mut routed = routed_stake::new<SHARE, SHARE>(
        &mut parent,
        balance::create_for_testing<SHARE>(1000),
        ctx,
    );

    routed.register(&mut other, &mut own_pool);
    abort
}

/// The `ENoStake` guard precedes the self-route check: an emptied wrapper
/// aborts `ENoStake` even when handed its parent's own pool.
#[test, expected_failure(abort_code = routed_stake::ENoStake, location = routed_stake)]
fun self_route_check_runs_after_the_no_stake_guard() {
    let ctx = &mut tx_context::dummy();
    let mut parent = object::new(ctx);
    let mut own_pool = pool::new_for_testing<SHARE, USD>(&mut parent);

    let mut routed = routed_stake::new<SHARE, SHARE>(
        &mut parent,
        balance::create_for_testing<SHARE>(1000),
        ctx,
    );
    destroy(routed.unstake(&mut parent));

    routed.register(&mut parent, &mut own_pool);
    abort
}

// === Must succeed: distinct objects, full lifecycle ===

/// Scenario 4: the v1 shape (`composition_routed_stake`) —
/// `RoutedStake<RecordingShare, CompositionShare>` under a composition,
/// earning from the recording's pool and routing into the composition's.
/// Different share types, so the parent's destination pool can never
/// collide with the stake pool; the whole lifecycle runs.
#[test]
fun v1_shape_different_share_types_full_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let mut recording = object::new(ctx);
    let mut composition = object::new(ctx);
    let composition_id = composition.to_inner();
    let mut recording_pool = pool::new_for_testing<RECORDING_SHARE, USD>(&mut recording);
    let mut composition_pool = pool::new_for_testing<COMPOSITION_SHARE, USD>(&mut composition);
    // The guard compares against the composition's own `<COMPOSITION_SHARE,
    // USD>` pool, which is a different object from the recording's pool.
    assert!(
        object::id(&recording_pool).to_address()
            != pool::derived_address<COMPOSITION_SHARE, USD>(composition_id),
    );

    let mut routed = routed_stake::new<RECORDING_SHARE, COMPOSITION_SHARE>(
        &mut composition,
        balance::create_for_testing<RECORDING_SHARE>(1000),
        ctx,
    );
    routed.register(&mut composition, &mut recording_pool);
    assert_eq!(routed.stake().registration_count(), 1);

    // Deposit → sweep moves the reward into the composition's pool, where a
    // registered holder can claim it.
    recording_pool.deposit(balance::create_for_testing<USD>(500));
    let mut holder = stake::new(balance::create_for_testing<COMPOSITION_SHARE>(100), ctx);
    composition_pool.register_stake(&mut holder);
    let value = routed.sweep(&mut recording_pool, &mut composition_pool, composition_id);
    assert_eq!(value, 500);
    assert_eq!(composition_pool.balance().value(), 500);
    assert_eq!(recording_pool.pending_rewards(routed.stake()), 0);
    let holder_reward = composition_pool.claim_rewards(&mut holder);
    assert_eq!(holder_reward.value(), 500);

    // Exit: unregister (rewards drained) → unstake returns the full principal.
    routed.unregister(&mut composition, &mut recording_pool);
    let principal = routed.unstake(&mut composition);
    assert_eq!(principal.value(), 1000);
    assert!(!routed.has_stake());

    destroy(holder_reward);
    destroy(holder);
    destroy(principal);
    destroy(routed);
    destroy(recording_pool);
    destroy(composition_pool);
    recording.delete();
    composition.delete();
}

/// Scenario 5: the same share type on both sides, but the stake pool is
/// derived from a *different* parent `Q`. This is the shape a type check
/// would wrongly forbid; the address check lets it through and the full
/// lifecycle runs, sweeping into `P`'s own `RoyaltyPool<S, C>`.
#[test]
fun same_share_type_under_a_different_parent_full_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let mut parent = object::new(ctx);
    let mut other_parent = object::new(ctx);
    let parent_id = parent.to_inner();
    let mut foreign_pool = pool::new_for_testing<SHARE, USD>(&mut other_parent);
    let mut own_pool = pool::new_for_testing<SHARE, USD>(&mut parent);
    // Same type, different derivation → different object.
    assert!(
        object::id(&foreign_pool).to_address() != pool::derived_address<SHARE, USD>(parent_id),
    );

    let mut routed = routed_stake::new<SHARE, SHARE>(
        &mut parent,
        balance::create_for_testing<SHARE>(1000),
        ctx,
    );
    routed.register(&mut parent, &mut foreign_pool);
    assert_eq!(routed.stake().registration_count(), 1);

    foreign_pool.deposit(balance::create_for_testing<USD>(500));
    let mut holder = stake::new(balance::create_for_testing<SHARE>(100), ctx);
    own_pool.register_stake(&mut holder);
    let value = routed.sweep(&mut foreign_pool, &mut own_pool, parent_id);
    assert_eq!(value, 500);
    assert_eq!(own_pool.balance().value(), 500);
    assert_eq!(foreign_pool.pending_rewards(routed.stake()), 0);
    let holder_reward = own_pool.claim_rewards(&mut holder);
    assert_eq!(holder_reward.value(), 500);

    routed.unregister(&mut parent, &mut foreign_pool);
    let principal = routed.unstake(&mut parent);
    assert_eq!(principal.value(), 1000);
    assert!(!routed.has_stake());

    destroy(holder_reward);
    destroy(holder);
    destroy(principal);
    destroy(routed);
    destroy(foreign_pool);
    destroy(own_pool);
    other_parent.delete();
    parent.delete();
}

/// Scenario 6: the stake pool is *also* derived from `P` — but under a
/// different share type (`RoyaltyPool<OTHER_SHARE, C>` next to the
/// destination `RoyaltyPool<SHARE, C>`). Two derived objects under one
/// parent, so `sweep` has two distinct `&mut` arguments and everything
/// works.
#[test]
fun different_share_types_both_pools_under_the_parent_full_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let mut parent = object::new(ctx);
    let parent_id = parent.to_inner();
    let mut stake_pool = pool::new_for_testing<OTHER_SHARE, USD>(&mut parent);
    let mut routed_pool = pool::new_for_testing<SHARE, USD>(&mut parent);
    assert!(object::id(&stake_pool) != object::id(&routed_pool));
    assert!(
        object::id(&stake_pool).to_address() != pool::derived_address<SHARE, USD>(parent_id),
    );

    let mut routed = routed_stake::new<OTHER_SHARE, SHARE>(
        &mut parent,
        balance::create_for_testing<OTHER_SHARE>(1000),
        ctx,
    );
    routed.register(&mut parent, &mut stake_pool);
    assert_eq!(routed.stake().registration_count(), 1);

    stake_pool.deposit(balance::create_for_testing<USD>(500));
    let mut holder = stake::new(balance::create_for_testing<SHARE>(100), ctx);
    routed_pool.register_stake(&mut holder);
    let value = routed.sweep(&mut stake_pool, &mut routed_pool, parent_id);
    assert_eq!(value, 500);
    assert_eq!(routed_pool.balance().value(), 500);
    let holder_reward = routed_pool.claim_rewards(&mut holder);
    assert_eq!(holder_reward.value(), 500);

    routed.unregister(&mut parent, &mut stake_pool);
    let principal = routed.unstake(&mut parent);
    assert_eq!(principal.value(), 1000);

    destroy(holder_reward);
    destroy(holder);
    destroy(principal);
    destroy(routed);
    destroy(stake_pool);
    destroy(routed_pool);
    parent.delete();
}

/// Scenario 7 (boundary): the guard is keyed on `(PoolShare, Currency)`, so
/// `P` owning same-share pools for *other* currencies is irrelevant to a
/// registration — only the pool for the registration's own currency is the
/// forbidden object. `RoutedStake<S, S>` under `P` registers for both `USD`
/// and `EUR` into `Q`'s pools while `P`'s own `USD` and `EUR` pools exist,
/// and each currency sweeps into its own destination and exits cleanly.
///
/// (Handing `P`'s own `RoyaltyPool<S, EUR>` to a `USD` registration is not
/// constructible — the registration currency *is* the pool's type
/// parameter — so "own pool, other currency" can only mean a self-route for
/// that other currency, which scenario 3 shows is refused.)
#[test]
fun own_pools_for_other_currencies_do_not_interfere() {
    let ctx = &mut tx_context::dummy();
    let mut parent = object::new(ctx);
    let mut other_parent = object::new(ctx);
    let parent_id = parent.to_inner();
    let mut foreign_usd_pool = pool::new_for_testing<SHARE, USD>(&mut other_parent);
    let mut foreign_eur_pool = pool::new_for_testing<SHARE, EUR>(&mut other_parent);
    let mut own_usd_pool = pool::new_for_testing<SHARE, USD>(&mut parent);
    let mut own_eur_pool = pool::new_for_testing<SHARE, EUR>(&mut parent);
    assert!(
        pool::derived_address<SHARE, USD>(parent_id) != pool::derived_address<SHARE, EUR>(parent_id),
    );

    let mut routed = routed_stake::new<SHARE, SHARE>(
        &mut parent,
        balance::create_for_testing<SHARE>(1000),
        ctx,
    );
    routed.register(&mut parent, &mut foreign_usd_pool);
    routed.register(&mut parent, &mut foreign_eur_pool);
    assert_eq!(routed.stake().registration_count(), 2);

    foreign_usd_pool.deposit(balance::create_for_testing<USD>(500));
    foreign_eur_pool.deposit(balance::create_for_testing<EUR>(300));
    let mut holder = stake::new(balance::create_for_testing<SHARE>(100), ctx);
    own_usd_pool.register_stake(&mut holder);
    own_eur_pool.register_stake(&mut holder);
    assert_eq!(routed.sweep(&mut foreign_usd_pool, &mut own_usd_pool, parent_id), 500);
    assert_eq!(routed.sweep(&mut foreign_eur_pool, &mut own_eur_pool, parent_id), 300);
    assert_eq!(own_usd_pool.balance().value(), 500);
    assert_eq!(own_eur_pool.balance().value(), 300);
    let usd_reward = own_usd_pool.claim_rewards(&mut holder);
    let eur_reward = own_eur_pool.claim_rewards(&mut holder);
    assert_eq!(usd_reward.value(), 500);
    assert_eq!(eur_reward.value(), 300);

    routed.unregister(&mut parent, &mut foreign_usd_pool);
    routed.unregister(&mut parent, &mut foreign_eur_pool);
    let principal = routed.unstake(&mut parent);
    assert_eq!(principal.value(), 1000);

    own_usd_pool.unregister_stake(&mut holder);
    own_eur_pool.unregister_stake(&mut holder);
    destroy(usd_reward);
    destroy(eur_reward);
    destroy(holder);
    destroy(principal);
    destroy(routed);
    destroy(foreign_usd_pool);
    destroy(foreign_eur_pool);
    destroy(own_usd_pool);
    destroy(own_eur_pool);
    other_parent.delete();
    parent.delete();
}

// === Must succeed: further shapes the address check must let through ===

/// Scenario 8: the parent's destination pool does not exist yet when
/// `register` runs. The guard is a pure derivation — it needs no object at
/// the derived address — so a same-typed foreign pool registers normally.
/// The parent then creates its own pool at that address; it is a different
/// object from the stake pool, so `sweep` is constructible (parked here, as
/// the fresh pool has no stakers) and the position exits cleanly.
#[test]
fun destination_pool_created_after_registration_still_sweeps_and_exits() {
    let ctx = &mut tx_context::dummy();
    let mut parent = object::new(ctx);
    let mut other_parent = object::new(ctx);
    let parent_id = parent.to_inner();
    let mut foreign_pool = pool::new_for_testing<SHARE, USD>(&mut other_parent);

    let mut routed = routed_stake::new<SHARE, SHARE>(
        &mut parent,
        balance::create_for_testing<SHARE>(1000),
        ctx,
    );
    // No `RoyaltyPool<SHARE, USD>` under `parent` exists at this point.
    routed.register(&mut parent, &mut foreign_pool);
    foreign_pool.deposit(balance::create_for_testing<USD>(500));
    assert_eq!(foreign_pool.pending_rewards(routed.stake()), 500);

    // The destination is created after the fact, at the guarded address.
    let mut own_pool = pool::new_for_testing<SHARE, USD>(&mut parent);
    assert_eq!(
        object::id(&own_pool).to_address(),
        pool::derived_address<SHARE, USD>(parent_id),
    );
    assert!(object::id(&own_pool) != object::id(&foreign_pool));
    let value = routed.sweep(&mut foreign_pool, &mut own_pool, parent_id);
    assert_eq!(value, 500);
    assert_eq!(foreign_pool.pending_rewards(routed.stake()), 0);

    routed.unregister(&mut parent, &mut foreign_pool);
    let principal = routed.unstake(&mut parent);
    assert_eq!(principal.value(), 1000);
    assert!(!routed.has_stake());

    destroy(principal);
    destroy(routed);
    destroy(foreign_pool);
    destroy(own_pool);
    parent.delete();
    other_parent.delete();
}

/// Scenario 9: two routed stakes under one parent forming a cycle *inside*
/// that parent. `RoutedStake<OTHER_SHARE, SHARE>` earns from P's
/// `RoyaltyPool<OTHER_SHARE, USD>` and routes into P's `RoyaltyPool<SHARE,
/// USD>`; `RoutedStake<SHARE, OTHER_SHARE>` earns from the latter and routes
/// into the former. Neither registration is a self-route — each stake pool
/// is a different derived object from that stake's own destination — so
/// both sweeps are constructible, the cycle decays past an external holder,
/// and both positions exit via sweep-then-unregister.
#[test]
fun cycle_inside_one_parent_is_not_a_self_route_and_both_exit() {
    let ctx = &mut tx_context::dummy();
    let mut parent = object::new(ctx);
    let parent_id = parent.to_inner();
    let mut pool_other = pool::new_for_testing<OTHER_SHARE, USD>(&mut parent);
    let mut pool_share = pool::new_for_testing<SHARE, USD>(&mut parent);

    let mut rs_a = routed_stake::new<OTHER_SHARE, SHARE>(
        &mut parent,
        balance::create_for_testing<OTHER_SHARE>(1000),
        ctx,
    );
    let mut rs_b = routed_stake::new<SHARE, OTHER_SHARE>(
        &mut parent,
        balance::create_for_testing<SHARE>(1000),
        ctx,
    );
    rs_a.register(&mut parent, &mut pool_other);
    rs_b.register(&mut parent, &mut pool_share);

    // An external holder in `pool_share` so the cycle decays.
    let mut holder = stake::new(balance::create_for_testing<SHARE>(1000), ctx);
    pool_share.register_stake(&mut holder);

    pool_other.deposit(balance::create_for_testing<USD>(1000));
    assert_eq!(rs_a.sweep(&mut pool_other, &mut pool_share, parent_id), 1000);
    // rs_b holds half of pool_share: half bounces back into pool_other.
    assert_eq!(rs_b.sweep(&mut pool_share, &mut pool_other, parent_id), 500);
    assert_eq!(rs_a.sweep(&mut pool_other, &mut pool_share, parent_id), 500);
    assert_eq!(rs_b.sweep(&mut pool_share, &mut pool_other, parent_id), 250);

    // Exit rs_a: a final sweep drains its pending, then unregister/unstake.
    assert_eq!(rs_a.sweep(&mut pool_other, &mut pool_share, parent_id), 250);
    rs_a.unregister(&mut parent, &mut pool_other);
    let principal_a = rs_a.unstake(&mut parent);
    assert_eq!(principal_a.value(), 1000);

    // Exit rs_b: its sweep now parks (pool_other has no stakers) and it
    // still exits.
    assert_eq!(rs_b.sweep(&mut pool_share, &mut pool_other, parent_id), 125);
    rs_b.unregister(&mut parent, &mut pool_share);
    let principal_b = rs_b.unstake(&mut parent);
    assert_eq!(principal_b.value(), 1000);

    // Value conserved: the holder ends with 500 + 250 + 125, 125 is parked
    // at pool_other's address, and pool_share is drained.
    let holder_reward = pool_share.claim_rewards(&mut holder);
    assert_eq!(holder_reward.value(), 875);
    assert_eq!(pool_share.balance().value(), 0);
    pool_share.unregister_stake(&mut holder);

    destroy(holder_reward);
    destroy(holder);
    destroy(principal_a);
    destroy(principal_b);
    destroy(rs_a);
    destroy(rs_b);
    destroy(pool_other);
    destroy(pool_share);
    parent.delete();
}

/// Scenario 10: two parents with the same share type. The guard keys on the
/// wrapper's *own* parent only: `RoutedStake<SHARE, SHARE>` under P earns
/// from Q's `RoyaltyPool<SHARE, USD>` while Q's own `RoutedStake<SHARE,
/// SHARE>` earns from R's. Sweeps chain R → Q → P and both positions exit;
/// nothing about Q's pool being someone else's destination interferes.
#[test]
fun two_parents_same_share_type_do_not_cross_guard() {
    let ctx = &mut tx_context::dummy();
    let mut p = object::new(ctx);
    let mut q = object::new(ctx);
    let mut r = object::new(ctx);
    let p_id = p.to_inner();
    let q_id = q.to_inner();
    let mut p_pool = pool::new_for_testing<SHARE, USD>(&mut p);
    let mut q_pool = pool::new_for_testing<SHARE, USD>(&mut q);
    let mut r_pool = pool::new_for_testing<SHARE, USD>(&mut r);

    let mut rs_p = routed_stake::new<SHARE, SHARE>(
        &mut p,
        balance::create_for_testing<SHARE>(100),
        ctx,
    );
    let mut rs_q = routed_stake::new<SHARE, SHARE>(
        &mut q,
        balance::create_for_testing<SHARE>(100),
        ctx,
    );
    rs_p.register(&mut p, &mut q_pool); // P earns from Q, routes into P
    rs_q.register(&mut q, &mut r_pool); // Q earns from R, routes into Q

    r_pool.deposit(balance::create_for_testing<USD>(300));
    assert_eq!(rs_q.sweep(&mut r_pool, &mut q_pool, q_id), 300);
    // rs_p is q_pool's only staker, so the 300 are now pending for it.
    assert_eq!(q_pool.pending_rewards(rs_p.stake()), 300);
    assert_eq!(rs_p.sweep(&mut q_pool, &mut p_pool, p_id), 300);

    rs_p.unregister(&mut p, &mut q_pool);
    rs_q.unregister(&mut q, &mut r_pool);
    let principal_p = rs_p.unstake(&mut p);
    let principal_q = rs_q.unstake(&mut q);
    assert_eq!(principal_p.value(), 100);
    assert_eq!(principal_q.value(), 100);

    destroy(principal_p);
    destroy(principal_q);
    destroy(rs_p);
    destroy(rs_q);
    destroy(p_pool);
    destroy(q_pool);
    destroy(r_pool);
    p.delete();
    q.delete();
    r.delete();
}

// === Guard ordering against the dependency ===

/// The self-route check precedes `pool::register_stake`'s own
/// `EAlreadyRegistered`: a stake legitimately registered for `USD` (in Q's
/// pool) that is then handed P's own `USD` pool aborts `ESelfRoute`, not the
/// dependency's code 2. This is intentional — a self-route is refused before
/// the dependency is consulted at all — and it is the one pre-existing
/// failure shape whose abort code changed with the guard (on `main` this
/// call reached `pool::register_stake` and aborted `EAlreadyRegistered`).
#[test, expected_failure(abort_code = routed_stake::ESelfRoute, location = routed_stake)]
fun self_route_check_runs_before_the_dependency_already_registered_guard() {
    let ctx = &mut tx_context::dummy();
    let mut parent = object::new(ctx);
    let mut other_parent = object::new(ctx);
    let mut foreign_pool = pool::new_for_testing<SHARE, USD>(&mut other_parent);
    let mut own_pool = pool::new_for_testing<SHARE, USD>(&mut parent);

    let mut routed = routed_stake::new<SHARE, SHARE>(
        &mut parent,
        balance::create_for_testing<SHARE>(1000),
        ctx,
    );
    routed.register(&mut parent, &mut foreign_pool);
    assert_eq!(routed.stake().registration_count(), 1);

    routed.register(&mut parent, &mut own_pool);
    abort
}
