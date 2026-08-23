/*
 * TTIOAcquisitionRun+Testing.h
 *
 * Exposes the unit planner and the window sizer to the test suite. Not
 * installed and not part of the public API.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import <Foundation/Foundation.h>
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOSpectralUnitPlan.h"

@interface TTIOAcquisitionRun (Testing)
- (NSArray<NSValue *> *)_unitsFrom:(NSUInteger)from to:(NSUInteger)to;
- (NSUInteger)_unitWindowForThreads:(NSUInteger)nthreads
                              units:(NSArray<NSValue *> *)units;
- (NSDictionary *)_fdzTablesForAllChannels;
/** Drops blocks/index so the planner falls to the header walk. */
- (void)_testDropBlockIndex;
@end
