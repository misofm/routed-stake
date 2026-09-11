// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module routed_stake::routed_stake_exit_event_tests;

use routed_stake::routed_stake::{Self};
use royalty_pool::pool::{Self, RoyaltyPool};
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::bcs;
use sui::event;

public struct A {}
public struct P {}
public struct U {}

#[test]
fun unregistered_unstaked_and_restaked_fields_are_exact() {
    let ctx = &mut tx_context::dummy();
    let mut ap = object::new(ctx); let mut pp = object::new(ctx);
    let mut sp = pool::new<A, U>(&mut ap); let dp = pool::new<P, U>(&mut pp);
    let pi = pp.to_inner(); let pa = pi.to_address();
    let mut r = routed_stake::new<A, P>(&mut pp, balance::create_for_testing<A>(1000), ctx);
    let ri = object::id(&r).to_address(); let si = object::id(r.stake()).to_address(); let spi = object::id(&sp).to_address();
    r.register(&mut pp, &mut sp);
    r.unregister(&mut pp, &mut sp);
    let ev = event::events_by_type<routed_stake::RoutedStakeUnregisteredEvent<A, P, U>>();
    let (a, b, c, d, e, f, g, h, i, j, k) = routed_stake::unregistered_event_fields(&ev[0]);
    assert_eq!(a, ri); assert_eq!(b, pa); assert_eq!(c, si); assert_eq!(d, spi); assert_eq!(e, 1000); assert_eq!(f, 1); assert_eq!(g, 0); assert_eq!(h, 1000); assert_eq!(i, 0); assert_eq!(j, 0); assert_eq!(k, 0); assert_eq!(bcs::to_bytes(&ev[0]).length(), 232);
    let principal = r.unstake(&mut pp);
    let ev = event::events_by_type<routed_stake::RoutedStakeUnstakedEvent<A, P>>();
    let (a, b, c, d) = routed_stake::unstaked_event_fields(&ev[0]);
    assert_eq!(a, ri); assert_eq!(b, pa); assert_eq!(c, si); assert_eq!(d, principal.value()); assert_eq!(bcs::to_bytes(&ev[0]).length(), 104);
    r.restake(&mut pp, balance::create_for_testing<A>(700), ctx);
    let rs = object::id(r.stake()).to_address();
    let ev = event::events_by_type<routed_stake::RoutedStakeRestakedEvent<A, P>>();
    let (a, b, c, d) = routed_stake::restaked_event_fields(&ev[0]);
    assert_eq!(a, ri); assert_eq!(b, pa); assert_eq!(c, rs); assert!(c != si); assert_eq!(d, 700); assert_eq!(bcs::to_bytes(&ev[0]).length(), 104);
    destroy(principal); destroy(r); destroy(sp); destroy(dp); ap.delete(); pp.delete();
}
