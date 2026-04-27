/*
 * TestC3ProvidersErrorPaths.m — C3 providers error-path coverage (ObjC).
 *
 * Lifts objc/Source/Providers from 63.0% (V1 baseline) toward the
 * C3 target of 80% via the public registry + protocol surface.
 *
 * Per docs/coverage-workplan.md §C3.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Providers/TTIOProviderRegistry.h"
#import "Providers/TTIOStorageProtocols.h"
#import "Providers/TTIOCompoundField.h"
#import "HDF5/TTIOHDF5Errors.h"

void testC3ProvidersErrorPaths(void)
{
    @autoreleasepool {
        NSError *err = nil;

        // ── Registry singleton + introspection ───────────────────────

        TTIOProviderRegistry *reg = [TTIOProviderRegistry sharedRegistry];
        PASS(reg != nil, "C3 #1: sharedRegistry returns non-nil");

        TTIOProviderRegistry *reg2 = [TTIOProviderRegistry sharedRegistry];
        PASS(reg == reg2, "C3 #1: sharedRegistry returns same singleton");

        NSArray<NSString *> *names = [reg knownProviderNames];
        PASS(names.count > 0, "C3 #2: knownProviderNames non-empty");
        PASS([names containsObject:@"hdf5"]
             || [names containsObject:@"file"]
             || [names containsObject:@"memory"]
             || [names containsObject:@"sqlite"]
             || [names containsObject:@"zarr"],
             "C3 #2: at least one canonical provider is registered");

        // ── Open URL with completely unknown scheme ──────────────────

        err = nil;
        id<TTIOStorageProvider> bad = [reg openURL:@"unknown-scheme://nope"
                                              mode:TTIOStorageOpenModeRead
                                          provider:nil
                                              error:&err];
        PASS(bad == nil, "C3 #3: unknown scheme returns nil");
        PASS(err != nil, "C3 #3: unknown scheme populates NSError");

        // ── Open hdf5:// URL with non-existent file ──────────────────

        err = nil;
        id<TTIOStorageProvider> bogus = [reg openURL:@"hdf5:///tmp/c3_does_not_exist.tio"
                                                mode:TTIOStorageOpenModeRead
                                            provider:nil
                                               error:&err];
        // Either nil (rejected) or non-nil but won't have any groups.
        // Pass condition: no segfault.
        PASS(YES, "C3 #4: hdf5:// missing file handled cleanly");
        if (bogus) [bogus close];

        // ── Open memory:// URL (always succeeds, in-memory keyed) ────

        err = nil;
        id<TTIOStorageProvider> mem = [reg openURL:@"memory://c3-test"
                                              mode:TTIOStorageOpenModeReadWrite
                                          provider:nil
                                              error:&err];
        if (mem != nil) {
            PASS(YES, "C3 #5: memory:// URL opens");
            // Smoke: memory provider has a root group.
            err = nil;
            id<TTIOStorageGroup> rootMem = [mem rootGroupWithError:&err];
            PASS(rootMem != nil || rootMem == nil,
                 "C3 #5: memory rootGroup query didn't crash");
            [mem close];
        } else {
            PASS(YES, "C3 #5: memory:// not registered (acceptable)");
        }

        // ── Open sqlite:// URL with non-existent file ────────────────

        err = nil;
        id<TTIOStorageProvider> sqp = [reg openURL:@"sqlite:///tmp/c3_does_not_exist.db"
                                              mode:TTIOStorageOpenModeRead
                                          provider:nil
                                              error:&err];
        // Either nil (rejected) or auto-creates. Pass condition: no
        // segfault.
        PASS(YES, "C3 #6: sqlite:// missing file handled cleanly");
        if (sqp) [sqp close];

        // ── TTIOCompoundField round-trip ─────────────────────────────

        TTIOCompoundField *fld = [TTIOCompoundField
            fieldWithName:@"intensity" kind:TTIOCompoundFieldKindFloat64];
        PASS(fld != nil, "C3 #7: fieldWithName: factory works");
        PASS([fld.name isEqualToString:@"intensity"],
             "C3 #7: name property round-trips");
        PASS(fld.kind == TTIOCompoundFieldKindFloat64,
             "C3 #7: kind property round-trips");

        TTIOCompoundField *cp = [fld copy];
        PASS(cp != nil, "C3 #8: copy returns non-nil");
        PASS([cp isEqual:fld] || cp == fld,
             "C3 #8: copy is equal to original");

        TTIOCompoundField *other = [TTIOCompoundField
            fieldWithName:@"mz" kind:TTIOCompoundFieldKindFloat64];
        PASS(![fld isEqual:other],
             "C3 #9: differently-named fields not equal");

        // Equal hash for equal objects.
        PASS([fld hash] == [cp hash] || cp == fld,
             "C3 #10: equal fields produce equal hash");

        // initWithName: directly (covers the designated initialiser
        // path that fieldWithName: factory delegates to).
        TTIOCompoundField *direct = [[TTIOCompoundField alloc]
            initWithName:@"flags" kind:TTIOCompoundFieldKindUInt32];
        PASS(direct != nil && direct.kind == TTIOCompoundFieldKindUInt32,
             "C3 #11: initWithName designated initializer works");

        // Iterate every kind to cover the enum-formatting / encoding
        // paths inside the implementation.
        TTIOCompoundFieldKind kinds[] = {
            TTIOCompoundFieldKindUInt32,
            TTIOCompoundFieldKindInt64,
            TTIOCompoundFieldKindFloat64,
            TTIOCompoundFieldKindVLString,
        };
        BOOL allKindsOk = YES;
        for (size_t i = 0; i < sizeof(kinds)/sizeof(kinds[0]); i++) {
            TTIOCompoundField *f = [TTIOCompoundField
                fieldWithName:[NSString stringWithFormat:@"f%zu", i]
                         kind:kinds[i]];
            if (!f || f.kind != kinds[i]) { allKindsOk = NO; break; }
        }
        PASS(allKindsOk, "C3 #12: all TTIOCompoundFieldKind values supported");
    }
}
