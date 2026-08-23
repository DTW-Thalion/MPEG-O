#ifndef TTIO_SUBJECT_H
#define TTIO_SUBJECT_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSCopying</p>
 * <p><em>Declared In:</em> Dataset/TTIOSubject.h</p>
 *
 * <p>A study Subject: the donor / patient / animal / object the sample
 * was drawn from. First-class TTI-O entity introduced in Stage 6 of
 * the transport-spec v0.11 work (Deferral 2). Persisted as
 * <code>/study/subjects/&lt;external_id&gt;/</code> per-row HDF5
 * groups.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.subject.Subject</code><br/>
 * Java: <code>global.thalion.ttio.Subject</code></p>
 */
@interface TTIOSubject : NSObject <NSCopying>

/** Stable, depositor-controlled identifier; primary key within the
 *  dataset. Required, non-empty, must not contain <code>'/'</code>
 *  (HDF5 group-name restriction). */
@property (readonly, copy) NSString *externalId;

/** Study acronym / cohort identifier. Free string;
 *  <code>@""</code> = unset. */
@property (readonly, copy) NSString *project;

/** Free string (e.g. <code>@"M"</code>, <code>@"F"</code>,
 *  <code>@"NA"</code>). No enumeration enforced;
 *  <code>@""</code> = unset. */
@property (readonly, copy) NSString *sex;

/** Four-digit year of birth, or <code>0</code> sentinel for unknown.
 *  Stored as int64 on disk; widened to int32 in the
 *  SUBJECT_METADATA Arrow transport payload (column-width
 *  consistency with the identification table). */
@property (readonly) int64_t birthYear;

/** Open extension slot. Keys are free strings; values are
 *  stringified. Serialised to disk as a sort-keys JSON object so the
 *  bytes are deterministic across Python / ObjC / Java. */
@property (readonly, copy) NSDictionary<NSString *, NSString *> *attributes;

/**
 * Designated initialiser. <code>nil</code> for the optional fields
 * is normalised to the defaults (<code>@""</code> for strings,
 * <code>@{}</code> for <code>attributes</code>).
 *
 * @param externalId Stable, depositor-controlled identifier
 *                   (required, non-empty, no <code>'/'</code>).
 * @param project    Study acronym / cohort identifier (may be nil).
 * @param sex        Free-form sex string (may be nil).
 * @param birthYear  Year of birth or 0 sentinel.
 * @param attributes Open extension dict (may be nil).
 * @return An initialised subject; raises
 *         <code>NSInvalidArgumentException</code> on validation
 *         failure (empty / slashed <code>externalId</code>).
 */
- (instancetype)initWithExternalId:(NSString *)externalId
                            project:(nullable NSString *)project
                                sex:(nullable NSString *)sex
                          birthYear:(int64_t)birthYear
                         attributes:(nullable NSDictionary<NSString *, NSString *> *)attributes;

/**
 * @return JSON serialisation of <code>attributes</code> with sorted
 *         keys, matching Java's <code>Subject.attributesJson()</code>
 *         and Python's <code>json.dumps(d, sort_keys=True,
 *         separators=(',', ':'))</code> byte-for-byte. Returns
 *         <code>@"{}"</code> for an empty map.
 */
- (NSString *)attributesJson;

@end

NS_ASSUME_NONNULL_END

#endif
