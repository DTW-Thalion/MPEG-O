// TTIORansNativeTest.m — Task 17 native rANS introspection.
//
// Verifies the +[TTIOFqzcompNx16Z backendName] introspection helper
// reports either the pure-ObjC fallback or a "native-<kernel>" string
// from libttio_rans (built under native/_build/). The test is
// build-agnostic: when libttio_rans.so is present, the GNUmakefile
// wires it in and the assertion exercises the native branch; when
// absent, the assertion exercises the pure-ObjC fallback.
//
// Mirrors:
//   python/tests/test_m94z_native_backend.py
//   java/src/test/java/global/thalion/ttio/codecs/TtioRansNativeTest.java
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Codecs/TTIOFqzcompNx16Z.h"

static void testTtioRansNativeBackendName(void)
{
    NSString *backend = [TTIOFqzcompNx16Z backendName];
    PASS(backend != nil, "backendName must not be nil");
    if (backend == nil) return;

    BOOL ok = [backend isEqualToString:@"pure-objc"]
           || [backend hasPrefix:@"native-"];
    PASS(ok, "backendName is either pure-objc or native-<kernel>; got=%@",
         backend);

    // If the build was wired up against libttio_rans, kernel suffix must
    // be one of the documented dispatch values.
    if ([backend hasPrefix:@"native-"]) {
        NSString *kernel = [backend substringFromIndex:7];
        BOOL knownKernel = [kernel isEqualToString:@"avx2"]
                        || [kernel isEqualToString:@"sse4.1"]
                        || [kernel isEqualToString:@"scalar"]
                        || [kernel isEqualToString:@"unknown"];
        PASS(knownKernel,
             "native kernel suffix is one of avx2/sse4.1/scalar/unknown; got=%@",
             kernel);
    }

    // Surface the resolved backend in the test log so CI and devs can
    // confirm at a glance which path was exercised.
    fprintf(stderr, "  TTIOFqzcompNx16Z backendName: %s\n",
            [backend UTF8String]);
}

void testTtioRansNative(void);
void testTtioRansNative(void)
{
    testTtioRansNativeBackendName();
}
