// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module routed_stake::routed_stake_silence_tests;

use routed_stake::routed_stake::{Self};
use royalty_pool::pool::{Self, RoyaltyPool, RoyaltyClaimedEvent};
use royalty_pool::stake;
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::event;

public struct A {}
public struct P {}
public struct U {}

fun setup(ctx: &mut TxContext): (UID, UID, RoyaltyPool<A, U>, RoyaltyPool<P, U>) {
    let mut a = object::new(ctx); let mut p = object::new(ctx);
    let sp = pool::new<A, U>(&mut a); let dp = pool::new<P, U>(&mut p);
    (a, p, sp, dp)
}

fun assert_silent() {
    assert_eq!(event::events_by_type<routed_stake::RoutedStakeSweptEvent<A, P, U>>().length(), 0);
    assert_eq!(event::events_by_type<RoyaltyClaimedEvent<A, U>>().length(), 0);
}

#[test]
fun zero_reward_emits_dependency_claim_only() {
    let ctx = &mut tx_context::dummy();
    let (asset, mut parent, mut sp, mut dp) = setup(ctx);
    let pi = parent.to_inner();
    let mut r = routed_stake::new<A, P>(&mut parent, balance::create_for_testing<A>(1000), ctx);
    r.register(&mut parent, &mut sp);
    assert_eq!(r.sweep(&mut sp, &mut dp, pi), 0);
    assert_eq!(event::events_by_type<routed_stake::RoutedStakeSweptEvent<A, P, U>>().length(), 0);
    let claims = event::events_by_type<RoyaltyClaimedEvent<A, U>>();
    assert_eq!(claims.length(), 1);
    let (_, _, reward) = pool::royalty_claimed_event_fields(&claims[0]);
    assert_eq!(reward, 0);
    r.unregister(&mut parent, &mut sp);
    destroy(r.unstake(&mut parent)); destroy(r); destroy(sp); destroy(dp); asset.delete(); parent.delete();
}

#[test]
fun empty_unregistered_and_wrong_source_are_wrapper_and_dependency_silent() {
    let ctx = &mut tx_context::dummy();
    let (asset, mut parent, mut sp, mut dp) = setup(ctx);
    let pi = parent.to_inner();
    let mut empty = routed_stake::new<A, P>(&mut parent, balance::create_for_testing<A>(1000), ctx);
    destroy(empty.unstake(&mut parent));
    assert_eq!(empty.sweep(&mut sp, &mut dp, pi), 0);
    assert_silent();
    destroy(empty); destroy(sp); destroy(dp); asset.delete(); parent.delete();

    let (asset, mut parent, mut sp, mut dp) = setup(ctx);
    let pi = parent.to_inner();
    let mut unregistered = routed_stake::new<A, P>(&mut parent, balance::create_for_testing<A>(1000), ctx);
    assert_eq!(unregistered.sweep(&mut sp, &mut dp, pi), 0);
    assert_silent();
    destroy(unregistered); destroy(sp); destroy(dp); asset.delete(); parent.delete();

    let (asset, mut parent, mut sp, mut dp) = setup(ctx);
    let pi = parent.to_inner(); let mut foreign_asset = object::new(ctx);
    let mut foreign = pool::new<A, U>(&mut foreign_asset);
    let mut wrong = routed_stake::new<A, P>(&mut parent, balance::create_for_testing<A>(1000), ctx);
    wrong.register(&mut parent, &mut sp);
    assert_eq!(wrong.sweep(&mut foreign, &mut dp, pi), 0);
    assert_silent();
    wrong.unregister(&mut parent, &mut sp); destroy(wrong.unstake(&mut parent));
    destroy(wrong); destroy(sp); destroy(foreign); destroy(dp); asset.delete(); foreign_asset.delete(); parent.delete();
}
