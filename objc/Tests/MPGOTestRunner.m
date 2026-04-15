#import <Foundation/Foundation.h>
#import "Testing.h"

/*
 * Phase 2 test runner — smoke tests only.
 *
 * Milestone 1 will add START_SET/END_SET blocks for each value class and
 * move the bodies into dedicated files (TestValueClasses.m, ...).
 *
 * For now this binary exists to prove the build chain compiles and links
 * libMPGO against the test tool under GNUStep Make.
 */

extern void testPhase2Smoke(void);

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        START_SET("MPGO Phase 2 smoke tests")
            testPhase2Smoke();
        END_SET("MPGO Phase 2 smoke tests")
    }
    return 0;
}
