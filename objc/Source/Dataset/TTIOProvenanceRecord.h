#ifndef TTIO_PROVENANCE_RECORD_H
#define TTIO_PROVENANCE_RECORD_H

#import <Foundation/Foundation.h>

/**
 * <heading>TTIOProvenanceRecord</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSCopying</p>
 * <p><em>Declared In:</em> Dataset/TTIOProvenanceRecord.h</p>
 *
 * <p>W3C PROV-compatible processing record: a list of input entity
 * URIs, a software activity (name + parameters), a list of output
 * entity URIs, and a Unix timestamp. Persisted as a row in the
 * <code>/study/provenance</code> compound dataset and per-run under
 * <code>&lt;run&gt;/provenance/steps</code>.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.provenance.ProvenanceRecord</code><br/>
 * Java: <code>global.thalion.ttio.ProvenanceRecord</code></p>
 */
@interface TTIOProvenanceRecord : NSObject <NSCopying>

/** Input-entity URIs consumed by the activity. */
@property (readonly, copy) NSArray<NSString *> *inputRefs;

/** Software activity identifier. */
@property (readonly, copy) NSString *software;

/** Activity parameters (free-form key/value). */
@property (readonly, copy) NSDictionary<NSString *, id> *parameters;

/** Output-entity URIs produced by the activity. */
@property (readonly, copy) NSArray<NSString *> *outputRefs;

/** Unix timestamp (seconds since epoch). */
@property (readonly) int64_t timestampUnix;

/**
 * Designated initialiser.
 *
 * @param inputs     Input-entity URIs.
 * @param software   Software identifier.
 * @param parameters Activity parameters.
 * @param outputs    Output-entity URIs.
 * @param timestamp  Unix timestamp.
 * @return An initialised provenance record.
 */
- (instancetype)initWithInputRefs:(NSArray<NSString *> *)inputs
                         software:(NSString *)software
                       parameters:(NSDictionary<NSString *, id> *)parameters
                       outputRefs:(NSArray<NSString *> *)outputs
                    timestampUnix:(int64_t)timestamp;

/**
 * @param ref Entity URI to test for.
 * @return <code>YES</code> if <code>inputRefs</code> contains
 *         <code>ref</code>.
 */
- (BOOL)containsInputRef:(NSString *)ref;

/** @return Plist-friendly dictionary representation. */
- (NSDictionary *)asPlist;

/**
 * @param plist Plist representation produced by
 *              <code>-asPlist</code>.
 * @return The reconstructed record.
 */
+ (instancetype)fromPlist:(NSDictionary *)plist;

@end

#endif
