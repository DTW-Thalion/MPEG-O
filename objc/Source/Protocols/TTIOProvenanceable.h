#ifndef TTIO_PROVENANCEABLE_H
#define TTIO_PROVENANCEABLE_H

#import <Foundation/Foundation.h>

@class TTIOProvenanceRecord;

/**
 * Objects conforming to TTIOProvenanceable carry a W3C PROV-compatible
 * chain of processing records. Every transformation applied to the data
 * contributes an entry; the chain makes the object self-documenting and
 * supports regulatory audit trails.
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: ttio.protocols.Provenanceable
 *   Java:   com.dtwthalion.ttio.protocols.Provenanceable
 */
@protocol TTIOProvenanceable <NSObject>

@required
- (void)addProcessingStep:(TTIOProvenanceRecord *)step;
- (NSArray<TTIOProvenanceRecord *> *)provenanceChain;
- (NSArray<NSString *> *)inputEntities;
- (NSArray<NSString *> *)outputEntities;

@end

#endif /* TTIO_PROVENANCEABLE_H */
