#ifndef MPGO_PROVENANCEABLE_H
#define MPGO_PROVENANCEABLE_H

#import <Foundation/Foundation.h>

@class MPGOProvenanceRecord;

/**
 * Objects conforming to MPGOProvenanceable carry a W3C PROV-compatible
 * chain of processing records. Every transformation applied to the data
 * contributes an entry; the chain makes the object self-documenting and
 * supports regulatory audit trails.
 */
@protocol MPGOProvenanceable <NSObject>

@required
- (void)addProcessingStep:(MPGOProvenanceRecord *)step;
- (NSArray<MPGOProvenanceRecord *> *)provenanceChain;
- (NSArray<NSString *> *)inputEntities;
- (NSArray<NSString *> *)outputEntities;

@end

#endif /* MPGO_PROVENANCEABLE_H */
