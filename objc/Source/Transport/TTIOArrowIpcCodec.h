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
 * payloads -- IDENTIFICATIONS_TABLE (0x16) and QUANTIFICATIONS_TABLE
 * (0x17). Wraps the Objective-C++ libarrow bridge in
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
 * </pre>
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

/** Encode the given identification rows as an Arrow IPC stream. */
+ (NSData *)encodeIdentifications:(NSArray<TTIOIdentification *> *)rows;

/** Decode an Arrow IPC stream into identification rows. Returns
 *  <code>@[]</code> for empty / <code>nil</code> input. */
+ (NSArray<TTIOIdentification *> *)decodeIdentifications:(nullable NSData *)ipc;

/** Encode the given quantification rows as an Arrow IPC stream. */
+ (NSData *)encodeQuantifications:(NSArray<TTIOQuantification *> *)rows;

/** Decode an Arrow IPC stream into quantification rows. Returns
 *  <code>@[]</code> for empty / <code>nil</code> input. */
+ (NSArray<TTIOQuantification *> *)decodeQuantifications:(nullable NSData *)ipc;

@end

NS_ASSUME_NONNULL_END

#endif
