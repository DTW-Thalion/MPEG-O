#ifndef TTIO_SAMPLE_H
#define TTIO_SAMPLE_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSCopying</p>
 * <p><em>Declared In:</em> Dataset/TTIOSample.h</p>
 *
 * <p>A biological / material Sample collected from a
 * <code>TTIOSubject</code>, or a standalone sample with no recorded
 * subject. First-class TTI-O entity introduced in Stage 6 of the
 * transport-spec v0.11 work (Deferral 2). Persisted as
 * <code>/study/samples/&lt;sample_id&gt;/</code> per-row HDF5 groups,
 * see design spec
 * <code>docs/superpowers/specs/2026-05-26-subjects-samples-design.md</code>
 * §4.2 and §5.</p>
 *
 * <p>The <code>sampleId</code> matches
 * <code>TTIOAcquisitionRun.sampleName</code> for the run →
 * sample link; that string remains the canonical link (no breaking
 * change in Stage 6). When both Sample rows and
 * <code>AcquisitionRun.sampleName</code> are present, applications
 * SHOULD treat <code>sampleName</code> as a foreign key into the
 * Sample list. No automatic enrichment.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.sample.Sample</code><br/>
 * Java: <code>global.thalion.ttio.Sample</code></p>
 */
@interface TTIOSample : NSObject <NSCopying>

/** Stable, depositor-controlled identifier; primary key within the
 *  dataset. Required, non-empty, must not contain <code>'/'</code>
 *  (HDF5 group-name restriction). */
@property (readonly, copy) NSString *sampleId;

/** Soft foreign key into the Subject list of the same dataset.
 *  Absent / unset = <code>@""</code>. A mismatch (non-empty value
 *  but no matching Subject) logs a WARNING during write; it is not
 *  an error. */
@property (readonly, copy) NSString *subjectExternalId;

/** Free string (e.g. <code>@"tissue"</code>, <code>@"plasma"</code>);
 *  <code>@""</code> = unset. */
@property (readonly, copy) NSString *sampleKind;

/** Unix seconds since epoch when the sample was collected, or
 *  <code>0</code> sentinel for unknown. Stored as int64 on disk and
 *  in the SAMPLE_METADATA Arrow transport payload. */
@property (readonly) int64_t collectedAt;

/** Open extension slot. Keys are free strings; values are
 *  stringified. Serialised to disk as a sort-keys JSON object so the
 *  bytes are deterministic across Python / ObjC / Java. */
@property (readonly, copy) NSDictionary<NSString *, NSString *> *attributes;

/**
 * Designated initialiser. <code>nil</code> for the optional fields
 * is normalised to the defaults (<code>@""</code> for strings,
 * <code>@{}</code> for <code>attributes</code>).
 *
 * @param sampleId          Primary key (required, non-empty, no
 *                          <code>'/'</code>).
 * @param subjectExternalId Soft FK to a Subject (may be nil).
 * @param sampleKind        Free-form kind string (may be nil).
 * @param collectedAt       Unix seconds or 0 sentinel.
 * @param attributes        Open extension dict (may be nil).
 * @return An initialised sample; raises
 *         <code>NSInvalidArgumentException</code> on validation
 *         failure (empty / slashed <code>sampleId</code>).
 */
- (instancetype)initWithSampleId:(NSString *)sampleId
               subjectExternalId:(nullable NSString *)subjectExternalId
                      sampleKind:(nullable NSString *)sampleKind
                     collectedAt:(int64_t)collectedAt
                      attributes:(nullable NSDictionary<NSString *, NSString *> *)attributes;

/**
 * @return JSON serialisation of <code>attributes</code> with sorted
 *         keys, matching Java's <code>Sample.attributesJson()</code>
 *         and Python's <code>json.dumps(d, sort_keys=True,
 *         separators=(',', ':'))</code> byte-for-byte. Returns
 *         <code>@"{}"</code> for an empty map.
 */
- (NSString *)attributesJson;

@end

NS_ASSUME_NONNULL_END

#endif
