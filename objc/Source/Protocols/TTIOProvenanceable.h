#ifndef TTIO_PROVENANCEABLE_H
#define TTIO_PROVENANCEABLE_H

#import <Foundation/Foundation.h>

@class TTIOProvenanceRecord;

/**
 * <heading>TTIOProvenanceable</heading>
 *
 * <p><em>Conforms To:</em> NSObject (root protocol)</p>
 * <p><em>Declared In:</em> Protocols/TTIOProvenanceable.h</p>
 *
 * <p>Declares the interface for objects that carry a W3C
 * PROV-compatible chain of processing records. Every transformation
 * applied to the data contributes an entry; the chain makes the
 * object self-documenting and supports regulatory audit trails.</p>
 *
 * <p>A <code>TTIOProvenanceRecord</code> captures
 * <em>(input entities &rarr; activity &rarr; output entities)</em>
 * with timestamps and CV-annotated activity descriptions. The chain
 * is append-only; existing records cannot be mutated once added.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.protocols.Provenanceable</code><br/>
 * Java: <code>global.thalion.ttio.protocols.Provenanceable</code></p>
 */
@protocol TTIOProvenanceable <NSObject>

@required

/**
 * Appends a processing-step record to the provenance chain.
 *
 * @param step The record to append. Records are stored in insertion
 *             order; appending the same record twice creates two
 *             distinct chain entries.
 */
- (void)addProcessingStep:(TTIOProvenanceRecord *)step;

/**
 * @return The full provenance chain in insertion order. Empty array
 *         if no processing steps have been recorded.
 */
- (NSArray<TTIOProvenanceRecord *> *)provenanceChain;

/**
 * @return Identifiers of every input entity referenced anywhere in
 *         the chain, in chain order with duplicates preserved.
 */
- (NSArray<NSString *> *)inputEntities;

/**
 * @return Identifiers of every output entity referenced anywhere in
 *         the chain, in chain order with duplicates preserved.
 */
- (NSArray<NSString *> *)outputEntities;

@end

#endif /* TTIO_PROVENANCEABLE_H */
