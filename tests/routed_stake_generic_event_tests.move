// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module routed_stake::routed_stake_generic_event_tests;

use routed_stake::routed_stake::{Self};
use royalty_pool::pool;
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::event;

public struct S1 {}
public struct S2 {}
public struct P1 {}
public struct P2 {}
public struct C1 {}
public struct C2 {}

#[test]
fun successful_phantom_instantiations_have_separate_typed_streams() {
    let ctx = &mut tx_context::dummy();
    let mut a1 = object::new(ctx); let mut a2 = object::new(ctx);
    let mut p1 = object::new(ctx); let mut p2 = object::new(ctx);
    let mut sp1 = pool::new<S1, C1>(&mut a1); let mut sp2 = pool::new<S2, C2>(&mut a2);
    let mut dp1 = pool::new<P1, C1>(&mut p1); let mut dp2 = pool::new<P2, C2>(&mut p2);
    let pi1 = p1.to_inner(); let pi2 = p2.to_inner();
    let mut r1 = routed_stake::new<S1, P1>(&mut p1, balance::create_for_testing<S1>(100), ctx);
    let mut r2 = routed_stake::new<S2, P2>(&mut p2, balance::create_for_testing<S2>(200), ctx);
    let ri1 = object::id(&r1).to_address(); let ri2 = object::id(&r2).to_address();
    let si1 = object::id(r1.stake()).to_address(); let si2 = object::id(r2.stake()).to_address();
    let ce1 = event::events_by_type<routed_stake::RoutedStakeCreatedEvent<S1, P1>>();
    let ce2 = event::events_by_type<routed_stake::RoutedStakeCreatedEvent<S2, P2>>();
    assert_eq!(ce1.length(), 1); assert_eq!(ce2.length(), 1);
    let (a, _, c, d) = routed_stake::created_event_fields(&ce1[0]); assert_eq!(a, ri1); assert_eq!(c, si1); assert_eq!(d, 100);
    let (a, _, c, d) = routed_stake::created_event_fields(&ce2[0]); assert_eq!(a, ri2); assert_eq!(c, si2); assert_eq!(d, 200);
    assert!(ri1 != ri2);

    r1.register(&mut p1, &mut sp1); r2.register(&mut p2, &mut sp2);
    let re1 = event::events_by_type<routed_stake::RoutedStakeRegisteredEvent<S1, P1, C1>>();
    let re2 = event::events_by_type<routed_stake::RoutedStakeRegisteredEvent<S2, P2, C2>>();
    assert_eq!(re1.length(), 1); assert_eq!(re2.length(), 1);
    let (a, _, c, d, _, _, _, _, _, _, _) = routed_stake::registered_event_fields(&re1[0]); assert_eq!(a, ri1); assert_eq!(c, si1); assert_eq!(d, object::id(&sp1).to_address());
    let (a, _, c, d, _, _, _, _, _, _, _) = routed_stake::registered_event_fields(&re2[0]); assert_eq!(a, ri2); assert_eq!(c, si2); assert_eq!(d, object::id(&sp2).to_address());

    sp1.deposit(balance::create_for_testing<C1>(10)); sp2.deposit(balance::create_for_testing<C2>(20));
    assert_eq!(r1.sweep(&mut sp1, &mut dp1, pi1), 10); assert_eq!(r2.sweep(&mut sp2, &mut dp2, pi2), 20);
    let se1 = event::events_by_type<routed_stake::RoutedStakeSweptEvent<S1, P1, C1>>();
    let se2 = event::events_by_type<routed_stake::RoutedStakeSweptEvent<S2, P2, C2>>();
    assert_eq!(se1.length(), 1); assert_eq!(se2.length(), 1);
    let (a, b, c, d) = routed_stake::swept_event_summary(&se1[0]); assert_eq!(a, ri1); assert_eq!(b, pi1.to_address()); assert_eq!(c, 10); assert_eq!(d, true);
    let (a, b, c, d) = routed_stake::swept_event_summary(&se2[0]); assert_eq!(a, ri2); assert_eq!(b, pi2.to_address()); assert_eq!(c, 20); assert_eq!(d, true);

    r1.unregister(&mut p1, &mut sp1); r2.unregister(&mut p2, &mut sp2);
    let ue1 = event::events_by_type<routed_stake::RoutedStakeUnregisteredEvent<S1, P1, C1>>();
    let ue2 = event::events_by_type<routed_stake::RoutedStakeUnregisteredEvent<S2, P2, C2>>();
    assert_eq!(ue1.length(), 1); assert_eq!(ue2.length(), 1);

    destroy(r1.unstake(&mut p1)); destroy(r2.unstake(&mut p2)); destroy(r1); destroy(r2);
    destroy(sp1); destroy(sp2); destroy(dp1); destroy(dp2); a1.delete(); a2.delete(); p1.delete(); p2.delete();
}
