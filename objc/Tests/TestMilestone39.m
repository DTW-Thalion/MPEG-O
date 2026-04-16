// Milestone 39: provider abstraction (ObjC part).
//
// Parametrised round-trip across the two shipping providers.
// If every assertion holds on both, the protocol contract is correct.

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Providers/MPGOStorageProtocols.h"
#import "Providers/MPGOProviderRegistry.h"
#import "Providers/MPGOHDF5Provider.h"
#import "Providers/MPGOMemoryProvider.h"
#import "Providers/MPGOCompoundField.h"
#import "ValueClasses/MPGOEnums.h"
#import <unistd.h>

static NSString *m39HDF5Path(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/mpgo_m39_%d_%@",
            (int)getpid(), suffix];
}

static void runRoundTripForProvider(NSString *providerName, NSString *url)
{
    NSString *label = [providerName copy];

    MPGOProviderRegistry *reg = [MPGOProviderRegistry sharedRegistry];
    NSError *err = nil;
    id<MPGOStorageProvider> p =
        [reg openURL:url mode:MPGOStorageOpenModeCreate
             provider:providerName error:&err];
    PASS(p != nil, "M39 (%s): open CREATE", [label UTF8String]);

    id<MPGOStorageGroup> root = [p rootGroupWithError:&err];
    PASS(root != nil, "M39 (%s): rootGroup", [label UTF8String]);

    PASS([root setAttributeValue:@"round-trip" forName:@"title" error:&err],
         "M39 (%s): setAttribute", [label UTF8String]);

    id<MPGOStorageGroup> study = [root createGroupNamed:@"study" error:&err];
    PASS(study != nil, "M39 (%s): createGroup", [label UTF8String]);

    PASS([study setAttributeValue:@(11) forName:@"version" error:&err],
         "M39 (%s): setIntegerAttribute", [label UTF8String]);

    // Primitive dataset round-trip
    double vals[] = { 1.0, 2.5, 3.14159, -0.001, 1e10 };
    id<MPGOStorageDataset> ds =
        [study createDatasetNamed:@"values"
                         precision:MPGOPrecisionFloat64
                            length:5
                         chunkSize:0
                       compression:MPGOCompressionNone
                  compressionLevel:0
                             error:&err];
    PASS(ds != nil, "M39 (%s): createDataset (primitive)", [label UTF8String]);
    NSData *payload = [NSData dataWithBytes:vals length:sizeof(vals)];
    PASS([ds writeAll:payload error:&err],
         "M39 (%s): writeAll (primitive)", [label UTF8String]);

    // Compound dataset round-trip
    NSArray *fields = @[
        [MPGOCompoundField fieldWithName:@"run_name" kind:MPGOCompoundFieldKindVLString],
        [MPGOCompoundField fieldWithName:@"spectrum_index" kind:MPGOCompoundFieldKindUInt32],
        [MPGOCompoundField fieldWithName:@"chemical_entity" kind:MPGOCompoundFieldKindVLString],
        [MPGOCompoundField fieldWithName:@"confidence_score" kind:MPGOCompoundFieldKindFloat64],
    ];
    NSArray *rows = @[
        @{@"run_name":        @"run_A",
          @"spectrum_index":  @(0),
          @"chemical_entity": @"CHEBI:15377",
          @"confidence_score":@(0.95)},
        @{@"run_name":        @"run_B",
          @"spectrum_index":  @(3),
          @"chemical_entity": @"CHEBI:17234",
          @"confidence_score":@(0.72)},
    ];
    id<MPGOStorageDataset> compound =
        [study createCompoundDatasetNamed:@"identifications"
                                     fields:fields
                                      count:rows.count
                                      error:&err];
    PASS(compound != nil, "M39 (%s): createCompoundDataset", [label UTF8String]);
    PASS([compound writeAll:rows error:&err],
         "M39 (%s): writeAll (compound)", [label UTF8String]);

    [p close];

    // Re-open read-only and verify
    p = [reg openURL:url mode:MPGOStorageOpenModeRead
            provider:providerName error:&err];
    PASS(p != nil, "M39 (%s): open READ", [label UTF8String]);
    root = [p rootGroupWithError:&err];

    id v = [root attributeValueForName:@"title" error:&err];
    if ([v isKindOfClass:[NSData class]]) {
        v = [[NSString alloc] initWithData:v encoding:NSUTF8StringEncoding];
    }
    PASS([[v description] isEqualToString:@"round-trip"],
         "M39 (%s): attribute round-trip", [label UTF8String]);

    study = [root openGroupNamed:@"study" error:&err];
    PASS(study != nil, "M39 (%s): openGroup", [label UTF8String]);
    PASS([study hasChildNamed:@"values"],
         "M39 (%s): hasChild primitive", [label UTF8String]);
    PASS([study hasChildNamed:@"identifications"],
         "M39 (%s): hasChild compound", [label UTF8String]);

    [p close];
}

void testMilestone39(void)
{
    // memory://
    runRoundTripForProvider(@"memory",
        [NSString stringWithFormat:@"memory://m39-%d", (int)getpid()]);
    [MPGOMemoryProvider discardStore:[NSString stringWithFormat:@"memory://m39-%d", (int)getpid()]];

    // hdf5 (bare path)
    NSString *path = m39HDF5Path(@"providers.mpgo");
    runRoundTripForProvider(@"hdf5", path);
    unlink([path fileSystemRepresentation]);

    // Registry discovery
    NSArray *known = [[MPGOProviderRegistry sharedRegistry] knownProviderNames];
    PASS([known containsObject:@"hdf5"], "M39: registry knows hdf5");
    PASS([known containsObject:@"memory"], "M39: registry knows memory");
}
