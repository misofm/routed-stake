// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module routed_stake::routed_stake_created_registered_tests;

use routed_stake::routed_stake::{Self};
use royalty_pool::pool::{Self, RoyaltyPool};
use royalty_pool::stake;
use std::type_name;
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::bcs;
use sui::event;

public struct A {}
public struct P {}
public struct U {}

#[test]
fun created_and_registered_fields_are_exact() {
    let ctx = &mut tx_context::dummy();
    let mut ap = object::new(ctx); let mut pp = object::new(ctx);
    let mut sp = pool::new<A, U>(&mut ap); let dp = pool::new<P, U>(&mut pp);
    let pi = pp.to_inner(); let pa = pi.to_address();
    let mut r = routed_stake::new<A, P>(&mut pp, balance::create_for_testing<A>(1000), ctx);
    let ri = object::id(&r).to_address(); let si = object::id(r.stake()).to_address(); let spi = object::id(&sp).to_address();
    let ev = event::events_by_type<routed_stake::RoutedStakeCreatedEvent<A, P>>();
    let (a, b, c, d) = routed_stake::created_event_fields(&ev[0]);
    assert_eq!(a, ri); assert_eq!(b, pa); assert_eq!(c, si); assert_eq!(d, 1000); assert_eq!(bcs::to_bytes(&ev[0]).length(), 104);
    let u = type_name::with_defining_ids<U>(); let cb = stake::registration_count(r.stake()); let sb = sp.staked_shares(); let ix = sp.cumulative_reward_per_share();
    r.register(&mut pp, &mut sp);
    let ca = stake::registration_count(r.stake()); let sa = sp.staked_shares(); let dd = stake::registration_debt(r.stake().get_registration(&u));
    let ev = event::events_by_type<routed_stake::RoutedStakeRegisteredEvent<A, P, U>>();
    let (a, b, c, d, e, f, g, h, i, j, k) = routed_stake::registered_event_fields(&ev[0]);
    assert_eq!(a, ri); assert_eq!(b, pa); assert_eq!(c, si); assert_eq!(d, spi); assert_eq!(e, 1000); assert_eq!(f, cb); assert_eq!(g, ca); assert_eq!(h, sb); assert_eq!(i, sa); assert_eq!(j, ix); assert_eq!(k, dd); assert_eq!(bcs::to_bytes(&ev[0]).length(), 232);
    destroy(r); destroy(sp); destroy(dp); ap.delete(); pp.delete();
}
