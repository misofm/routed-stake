// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module routed_stake::routed_stake_parked_event_tests;

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
fun parked_sweep_event_asserts_all_destination_fields() {
    let ctx = &mut tx_context::dummy();
    let mut ap = object::new(ctx); let mut pp = object::new(ctx);
    let mut sp = pool::new<A, U>(&mut ap); let mut dp = pool::new<P, U>(&mut pp);
    let pi = pp.to_inner(); let pa = pi.to_address();
    let mut r = routed_stake::new<A, P>(&mut pp, balance::create_for_testing<A>(1000), ctx);
    let ri = object::id(&r).to_address(); let si = object::id(r.stake()).to_address();
    let spi = object::id(&sp).to_address(); let dpi = object::id(&dp).to_address();
    r.register(&mut pp, &mut sp); sp.deposit(balance::create_for_testing<U>(500));
    assert_eq!(r.sweep(&mut sp, &mut dp, pi), 500);
    let ev = event::events_by_type<routed_stake::RoutedStakeSweptEvent<A, P, U>>();
    let (a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r0, s0, t, u0, v, w, x, y) = routed_stake::swept_event_fields(&ev[0]);
    assert_eq!(a, ri); assert_eq!(b, pa); assert_eq!(c, si); assert_eq!(d, spi); assert_eq!(e, dpi);
    assert_eq!(f, 500); assert_eq!(g, true); assert_eq!(h, 1000); assert_eq!(i, 500); assert_eq!(j, 0);
    assert_eq!(k, 1000); assert_eq!(l, 500000000000000000); assert_eq!(m, 0); assert_eq!(n, 500);
    assert_eq!(o, 0); assert_eq!(p, 500000000000000000000); assert_eq!(q, 0); assert_eq!(r0, 0);
    assert_eq!(s0, 0); assert_eq!(t, 0); assert_eq!(u0, 0); assert_eq!(v, 0); assert_eq!(w, 0); assert_eq!(x, 0); assert_eq!(y, 0);
    assert_eq!(bcs::to_bytes(&ev[0]).length(), 481);
    r.unregister(&mut pp, &mut sp); destroy(r.unstake(&mut pp)); destroy(r); destroy(sp); destroy(dp); ap.delete(); pp.delete();
}
