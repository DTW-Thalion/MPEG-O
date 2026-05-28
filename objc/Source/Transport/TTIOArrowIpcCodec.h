/*
 * TTIOArrowIpcCodec.h
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOArrowIpcCodec
 * Inherits From: NSObject
 * Conforms To:   (none)
 * Declared In:   Transport/TTIOArrowIpcCodec.h
 *
 * Stateless Arrow IPC encoder/decoder for transport-spec v0.11 tabular
 * payloads -- IDENTIFICATIONS_TABLE (0x16), QUANTIFICATIONS_TABLE
 * (0x17), SUBJECT_METADATA (0x19, Stage 6), and SAMPLE_METADATA (0x1A,
 * Stage 6). Wraps the Objective-C++ libarrow bridge in
 * TTIOArrowIpcBridge.mm so callers can stay in pure Objective-C.
 *
 * Cross-language equivalents:
 *   Java:   global.thalion.ttio.transport.ArrowIpcCodec
 *   Python: ttio.transport.arrow_ipc
 *
 * Payloads are LOGICALLY equivalent across SDKs (same schema, same row
 * order, same column values) but are NOT byte-identical -- Arrow IPC
 * flatbuffer framing differs slightly across language bindings. All
 * three SDKs round-trip each other's bytes.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#ifndef TTIO_ARROW_IPC_CODEC_H
#define TTIO_ARROW_IPC_CODEC_H

#import <Foundation/Foundation.h>

@class TTIOIdentification;
@class TTIOQuantification;
@class TTIOSubject;
@class TTIOSample;

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Declared In:</em> Transport/TTIOArrowIpcCodec.h</p>
 *
 * <p>Apache Arrow IPC encode/decode for the v0.11 IDENTIFICATIONS_TABLE
 * (packet 0x16) and QUANTIFICATIONS_TABLE (packet 0x17) payloads.</p>
 *
 * <p><b>Schemas</b> (parity with Java + Python):</p>
 * <pre>
 *   IDENTIFICATION_SCHEMA:
 *     run_name             : utf8
 *     spectrum_index       : int32
 *     chemical_entity      : utf8
 *     confidence_score     : float64
 *     evidence_chain_json  : utf8     // JSON array of strings
 *
 *   QUANTIFICATION_SCHEMA:
 *     chemical_entity      : utf8
 *     sample_ref           : utf8
 *     abundance            : float64
 *     normalization_method : utf8
 *     unit                 : utf8
 *
 *   SUBJECT_SCHEMA (Stage 6, design spec §6.1):
 *     external_id          : utf8  (notNullable)
 *     project              : utf8  (nullable)
 *     sex                  : utf8  (nullable)
 *     birth_year           : int32 (nullable)   // widened from on-disk int64
 *     attributes_json      : utf8  (nullable)
 *
 *   SAMPLE_SCHEMA (Stage 6, design spec §6.2):
 *     sample_id            : utf8  (notNullable)
 *     subject_external_id  : utf8  (nullable)
 *     sample_kind          : utf8  (nullable)
 *     collected_at         : int64 (nullable)
 *     attributes_json      : utf8  (nullable)
 * </pre>
 *
 * <p><b>Subject / Sample null handling</b> (mirrors Java +
 * Python, spec §11):</p>
 * <ul>
 *   <li>Optional string columns (<code>project</code>,
 *       <code>sex</code>, <code>subject_external_id</code>,
 *       <code>sample_kind</code>) emit Arrow <i>null</i> when the
 *       source <code>NSString</code> is empty. On read, Arrow null
 *       decodes back to <code>@""</code>.</li>
 *   <li>Optional integer columns (<code>birth_year</code>,
 *       <code>collected_at</code>) emit Arrow <i>null</i> when the
 *       source value is the sentinel <code>0</code>. Arrow null
 *       decodes back to <code>0</code>.</li>
 *   <li>The <code>attributes_json</code> column is always present
 *       (<code>@"{}"</code> for empty maps), never Arrow null.</li>
 * </ul>
 *
 * <p>An empty input list yields a valid Arrow IPC stream that
 * round-trips to an empty array. Decoding <code>nil</code> or empty
 * data returns <code>@[]</code>.</p>
 *
 * <p>This codec emits only the IPC payload bytes -- the surrounding
 * 24-byte transport-spec packet header (with length prefix, CRC, ...)
 * is the caller's responsibility.</p>
 *
 * <p><b>API status:</b> Stable.</p>
 */
@interface TTIOArrowIpcCodec : NSObject

/**
 * Encode an array of identification rows as an Arrow IPC stream.
 *
 * Produces the IDENTIFICATION_SCHEMA-shaped payload bytes for the
 * IDENTIFICATIONS_TABLE (packet 0x16) transport payload. An empty input
 * still yields a valid Arrow IPC stream that decodes back to `@[]`.
 *
 * @param rows  Array of `TTIOIdentification` rows (may be empty, must be
 *              non-`nil`).
 * @return Arrow IPC stream bytes ready for transport framing. Caller is
 *         responsible for the 24-byte transport-spec packet header.
 */
+ (NSData *)encodeIdentifications:(NSArray<TTIOIdentification *> *)rows;

/**
 * Decode an Arrow IPC stream into `TTIOIdentification` rows.
 *
 * Inverse of `+encodeIdentifications:`. Tolerant of empty / `nil` input.
 *
 * @param ipc  Arrow IPC payload bytes (typically the body of a 0x16
 *             IDENTIFICATIONS_TABLE packet), or `nil`.
 * @return Decoded identification rows in source order. Returns `@[]` for
 *         `nil` or empty input.
 */
+ (NSArray<TTIOIdentification *> *)decodeIdentifications:(nullable NSData *)ipc;

/**
 * Encode an array of quantification rows as an Arrow IPC stream.
 *
 * Produces the QUANTIFICATION_SCHEMA-shaped payload bytes for the
 * QUANTIFICATIONS_TABLE (packet 0x17) transport payload. An empty input
 * still yields a valid Arrow IPC stream that decodes back to `@[]`.
 *
 * @param rows  Array of `TTIOQuantification` rows (may be empty, must be
 *              non-`nil`).
 * @return Arrow IPC stream bytes ready for transport framing.
 */
+ (NSData *)encodeQuantifications:(NSArray<TTIOQuantification *> *)rows;

/**
 * Decode an Arrow IPC stream into `TTIOQuantification` rows.
 *
 * Inverse of `+encodeQuantifications:`. Tolerant of empty / `nil` input.
 *
 * @param ipc  Arrow IPC payload bytes (typically the body of a 0x17
 *             QUANTIFICATIONS_TABLE packet), or `nil`.
 * @return Decoded quantification rows in source order. Returns `@[]` for
 *         `nil` or empty input.
 */
+ (NSArray<TTIOQuantification *> *)decodeQuantifications:(nullable NSData *)ipc;

/**
 * Encode an array of subject rows as an Arrow IPC stream.
 *
 * Produces the SUBJECT_SCHEMA-shaped payload bytes for the
 * SUBJECT_METADATA (packet 0x19) transport payload. Optional string
 * columns (`project`, `sex`) emit Arrow null for empty `NSString`s;
 * optional `birth_year` emits Arrow null for the `0` sentinel.
 *
 * @param rows  Array of `TTIOSubject` rows (may be empty, must be
 *              non-`nil`).
 * @return Arrow IPC stream bytes ready for transport framing.
 */
+ (NSData *)encodeSubjects:(NSArray<TTIOSubject *> *)rows;

/**
 * Decode an Arrow IPC stream into `TTIOSubject` rows.
 *
 * Inverse of `+encodeSubjects:`. Arrow null in `project` / `sex`
 * decodes back to `@""`; Arrow null in `birth_year` decodes back to `0`.
 *
 * @param ipc  Arrow IPC payload bytes (typically the body of a 0x19
 *             SUBJECT_METADATA packet), or `nil`.
 * @return Decoded subject rows in source order. Returns `@[]` for `nil`
 *         or empty input.
 */
+ (NSArray<TTIOSubject *> *)decodeSubjects:(nullable NSData *)ipc;

/**
 * Encode an array of sample rows as an Arrow IPC stream.
 *
 * Produces the SAMPLE_SCHEMA-shaped payload bytes for the
 * SAMPLE_METADATA (packet 0x1A) transport payload. Optional string
 * columns (`subject_external_id`, `sample_kind`) emit Arrow null for
 * empty strings; `collected_at` emits Arrow null for the `0` sentinel.
 *
 * @param rows  Array of `TTIOSample` rows (may be empty, must be
 *              non-`nil`).
 * @return Arrow IPC stream bytes ready for transport framing.
 */
+ (NSData *)encodeSamples:(NSArray<TTIOSample *> *)rows;

/**
 * Decode an Arrow IPC stream into `TTIOSample` rows.
 *
 * Inverse of `+encodeSamples:`. Arrow null in `subject_external_id` /
 * `sample_kind` decodes back to `@""`; Arrow null in `collected_at`
 * decodes back to `0`.
 *
 * @param ipc  Arrow IPC payload bytes (typically the body of a 0x1A
 *             SAMPLE_METADATA packet), or `nil`.
 * @return Decoded sample rows in source order. Returns `@[]` for `nil`
 *         or empty input.
 */
+ (NSArray<TTIOSample *> *)decodeSamples:(nullable NSData *)ipc;

@end

NS_ASSUME_NONNULL_END

#endif
