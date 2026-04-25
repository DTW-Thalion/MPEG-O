#ifndef TTIO_PROVENANCE_RECORD_H
#define TTIO_PROVENANCE_RECORD_H

#import <Foundation/Foundation.h>

/**
 * W3C PROV-compatible processing record: a list of input entity URIs,
 * a software activity (name + parameters), a list of output entity URIs,
 * and a Unix timestamp. Stored in /study/&lt;run&gt;/provenance/steps as a
 * JSON-encoded array on disk.
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: ttio.provenance.ProvenanceRecord
 *   Java:   com.dtwthalion.tio.ProvenanceRecord
 */
@interface TTIOProvenanceRecord : NSObject <NSCopying>

@property (readonly, copy) NSArray<NSString *> *inputRefs;
@property (readonly, copy) NSString *software;
@property (readonly, copy) NSDictionary<NSString *, id> *parameters;
@property (readonly, copy) NSArray<NSString *> *outputRefs;
@property (readonly)       int64_t timestampUnix;

- (instancetype)initWithInputRefs:(NSArray<NSString *> *)inputs
                         software:(NSString *)software
                       parameters:(NSDictionary<NSString *, id> *)parameters
                       outputRefs:(NSArray<NSString *> *)outputs
                    timestampUnix:(int64_t)timestamp;

- (BOOL)containsInputRef:(NSString *)ref;

- (NSDictionary *)asPlist;
+ (instancetype)fromPlist:(NSDictionary *)plist;

@end

#endif
