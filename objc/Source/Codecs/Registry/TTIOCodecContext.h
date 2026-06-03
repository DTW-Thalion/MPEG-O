#import <Foundation/Foundation.h>
#import "Codecs/TTIOReferenceResolver.h"
NS_ASSUME_NONNULL_BEGIN

/** Run-derived context for codecs. All fields optional/nullable; plain codecs ignore it. */
@interface TTIOCodecContext : NSObject
@property (nullable, strong) NSArray<NSNumber *> *readLengths;     // fqzcomp
@property (nullable, strong) NSArray<NSNumber *> *revcompFlags;    // fqzcomp
@property (nullable, strong) NSNumber *elementSize;               // delta encode
@property (nullable, strong) NSNumber *readCount;
@property (nullable, strong) NSData *positions;                  // int64-LE
@property (nullable, copy)   NSArray<NSString *> *(^cigarsProvider)(void);  // lazy thunk
@property (nullable, strong) NSNumber *totalBases;
@property (nullable, strong) NSArray<NSString *> *chromosomes;
@property (nullable, strong) NSData *ownChromIds;                // mate_info
@property (nullable, strong) NSData *ownPositions;               // mate_info
@property (nullable, strong) NSNumber *nRecords;
@property (nullable, strong) TTIOReferenceResolver *referenceResolver;
// encode-only (ref_diff):
@property (nullable, strong) NSData *offsets;
@property (nullable, strong) NSData *reference;
@property (nullable, strong) NSData *referenceMd5;
@property (nullable, strong) NSString *referenceUri;
@property (nullable, strong) NSNumber *readsPerSlice;

+ (instancetype)emptyContext;
@end

NS_ASSUME_NONNULL_END
