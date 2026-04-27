/*
 * SPDX-License-Identifier: Apache-2.0
 */
#import "TTIOCramWriter.h"

@interface TTIOBamWriter (TTIOCramWriterOverride)
- (NSArray<NSArray<NSString *> *> *)samtoolsCommandsForSort:(BOOL)sort;
@end

@implementation TTIOCramWriter

// NS_UNAVAILABLE in the header documents intent for clients; the
// inherited implementation is still emitted for binary compat.
- (instancetype)initWithPath:(NSString *)path
{
    return [super initWithPath:path];
}

- (instancetype)initWithPath:(NSString *)path
              referenceFasta:(NSString *)referenceFasta
{
    self = [super initWithPath:path];
    if (self) {
        _referenceFasta = [referenceFasta copy];
    }
    return self;
}

- (NSArray<NSArray<NSString *> *> *)samtoolsCommandsForSort:(BOOL)sort
{
    NSString *ref = _referenceFasta ?: @"";
    if (sort) {
        return @[
            @[@"view", @"-CS", @"--reference", ref, @"-"],
            @[@"sort", @"-O", @"cram", @"--reference", ref,
              @"-o", self.path, @"-"],
        ];
    } else {
        return @[
            @[@"view", @"-CS", @"--reference", ref,
              @"-o", self.path, @"-"],
        ];
    }
}

@end
