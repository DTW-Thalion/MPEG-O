/*
 * TTIOPerAUEncryption.h
 * TTI-O Objective-C Implementation
 *
 * Per-Access-Unit encryption primitives. Implements the AAD binding
 * rules from docs/transport-spec.md §4.3.4 and the
 * <channel>_segments / au_header_segments compound layout from
 * docs/format-spec.md §9.1.
 *
 * Cross-language equivalents:
 *   Python: ttio.encryption_per_au
 *   Java:   global.thalion.ttio.protection.PerAUEncryption
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#ifndef TTIO_PER_AU_ENCRYPTION_H
#define TTIO_PER_AU_ENCRYPTION_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** One encrypted row of a ``<channel>_segments`` compound dataset. */
@interface TTIOChannelSegment : NSObject

@property (nonatomic, readonly) uint64_t offset;
@property (nonatomic, readonly) uint32_t length;
@property (nonatomic, readonly, strong) NSData *iv;         /* 12 bytes */
@property (nonatomic, readonly, strong) NSData *tag;        /* 16 bytes */
@property (nonatomic, readonly, strong) NSData *ciphertext;

/**
 * Initialise a channel-segment row from its constituent fields.
 *
 * Used by the encryption pipeline to assemble per-AU rows for the
 * `<channel>_segments` compound dataset.
 *
 * @param offset      Plaintext-side row offset (in elements, not bytes).
 * @param length      Plaintext-side row length (in elements, not bytes).
 * @param iv          12-byte GCM nonce used to encrypt this row.
 * @param tag         16-byte GCM authentication tag.
 * @param ciphertext  Encrypted row payload bytes.
 * @return New `TTIOChannelSegment` instance holding the supplied fields.
 */
- (instancetype)initWithOffset:(uint64_t)offset
                          length:(uint32_t)length
                              iv:(NSData *)iv
                             tag:(NSData *)tag
                      ciphertext:(NSData *)ciphertext;

@end


/** One encrypted row of ``spectrum_index/au_header_segments``. */
@interface TTIOHeaderSegment : NSObject

@property (nonatomic, readonly, strong) NSData *iv;         /* 12 bytes */
@property (nonatomic, readonly, strong) NSData *tag;        /* 16 bytes */
@property (nonatomic, readonly, strong) NSData *ciphertext; /* 36 bytes */

/**
 * Initialise a header-segment row from its constituent fields.
 *
 * Used by the encryption pipeline to assemble per-AU rows for the
 * `au_header_segments` compound dataset.
 *
 * @param iv          12-byte GCM nonce used to encrypt this header.
 * @param tag         16-byte GCM authentication tag.
 * @param ciphertext  Encrypted 36-byte AU-header payload.
 * @return New `TTIOHeaderSegment` instance holding the supplied fields.
 */
- (instancetype)initWithIV:(NSData *)iv
                        tag:(NSData *)tag
                 ciphertext:(NSData *)ciphertext;

@end


/** Plaintext form of the 36-byte AU semantic header. */
@interface TTIOAUHeaderPlaintext : NSObject

@property (nonatomic) uint8_t  acquisitionMode;
@property (nonatomic) uint8_t  msLevel;
@property (nonatomic) int32_t  polarity;
@property (nonatomic) double   retentionTime;
@property (nonatomic) double   precursorMz;
@property (nonatomic) uint8_t  precursorCharge;
@property (nonatomic) double   ionMobility;
@property (nonatomic) double   basePeakIntensity;

@end


/**
 * Per-AU encryption primitives. All class methods; no instance state.
 */
@interface TTIOPerAUEncryption : NSObject

#pragma mark - AAD

/**
 * Build the AES-GCM additional-authenticated-data for a channel payload.
 *
 * Returns the byte layout
 * `dataset_id (u16 LE) || au_sequence (u32 LE) || channel_name_utf8`
 * required by the transport-spec §4.3.4 AAD binding rules.
 *
 * @param channelName  Channel name, UTF-8 encoded into the AAD tail.
 * @param datasetId    Dataset identifier (u16 LE).
 * @param auSequence   AU sequence number within the dataset (u32 LE).
 * @return AAD bytes ready to pass to `+encryptWithPlaintext:...`.
 */
+ (NSData *)aadForChannel:(NSString *)channelName
                  datasetId:(uint16_t)datasetId
                 auSequence:(uint32_t)auSequence;

/**
 * Build the AAD for an encrypted semantic-header payload.
 *
 * Same prefix as `+aadForChannel:...` with the literal byte string
 * `b"header"` appended in place of the channel name.
 *
 * @param datasetId   Dataset identifier (u16 LE).
 * @param auSequence  AU sequence number within the dataset (u32 LE).
 * @return AAD bytes for the AU-header segment.
 */
+ (NSData *)aadForHeaderWithDatasetId:(uint16_t)datasetId
                             auSequence:(uint32_t)auSequence;

/**
 * Build the AAD for an encrypted pixel-envelope payload.
 *
 * Same prefix as `+aadForChannel:...` with the literal byte string
 * `b"pixel"` appended in place of the channel name.
 *
 * @param datasetId   Dataset identifier (u16 LE).
 * @param auSequence  AU sequence number within the dataset (u32 LE).
 * @return AAD bytes for the pixel envelope.
 */
+ (NSData *)aadForPixelWithDatasetId:(uint16_t)datasetId
                            auSequence:(uint32_t)auSequence;


#pragma mark - Low-level AES-GCM with AAD

/** AES-256-GCM encrypt with authenticated data. Returns ciphertext;
 *  populates ``*outTag`` with 16-byte GCM tag. ``iv`` must be
 *  12 bytes. Random nonces should be generated with a CSPRNG and
 *  passed in by the caller (testing uses fixed IVs for determinism). */
+ (nullable NSData *)encryptWithPlaintext:(NSData *)plaintext
                                         key:(NSData *)key
                                          iv:(NSData *)iv
                                         aad:(NSData *)aad
                                      outTag:(NSData **)outTag
                                       error:(NSError * _Nullable *)error;

/**
 * AES-256-GCM decrypt with authenticated-data verification.
 *
 * Returns plaintext only when the 16-byte GCM tag matches; otherwise
 * fails cleanly (no partial-byte leakage).
 *
 * @param ciphertext  Encrypted payload bytes.
 * @param key         32-byte AES-256 key (same as encrypt).
 * @param iv          12-byte GCM nonce (same as encrypt).
 * @param tag         16-byte GCM authentication tag.
 * @param aad         Additional authenticated data (same as encrypt).
 * @param error       Out-error on tag mismatch / bad key / bad AAD.
 * @return Plaintext bytes on success, or `nil` with `*error` set.
 */
+ (nullable NSData *)decryptWithCiphertext:(NSData *)ciphertext
                                          key:(NSData *)key
                                           iv:(NSData *)iv
                                          tag:(NSData *)tag
                                          aad:(NSData *)aad
                                        error:(NSError * _Nullable *)error;

/**
 * Generate a fresh cryptographically-random 12-byte GCM nonce.
 *
 * Drives OpenSSL `RAND_bytes`. Used by the encrypt path when the
 * caller does not supply a deterministic IV (e.g. production
 * encryption, as opposed to fixed-IV test vectors).
 *
 * @param error  Out-error on RNG failure.
 * @return 12-byte random IV on success, or `nil` with `*error` set.
 */
+ (nullable NSData *)randomIVWithError:(NSError * _Nullable *)error;


#pragma mark - Channel segments

/** Slice ``plaintextFloat64`` into per-spectrum rows and encrypt each
 *  independently with a fresh IV. ``plaintextFloat64`` is a flat float64
 *  LE buffer; ``offsets[i]`` and ``lengths[i]`` index the i-th
 *  spectrum's slice.
 *
 *  Convenience overload that calls the generalised method below with
 *  ``bytesPerElement = 8`` (float64). MS callers stay on this entry
 *  point; genomic callers reach for the bytesPerElement form. */
+ (nullable NSArray<TTIOChannelSegment *> *)
    encryptChannelToSegments:(NSData *)plaintextFloat64
                      offsets:(const uint64_t *)offsets
                      lengths:(const uint32_t *)lengths
                     nSpectra:(NSUInteger)nSpectra
                    datasetId:(uint16_t)datasetId
                  channelName:(NSString *)channelName
                          key:(NSData *)key
                        error:(NSError * _Nullable *)error;

/** Generalised: ``bytesPerElement`` is the per-element byte width
 *  (8 for float64 MS path, 1 for uint8 genomic path).
 *  ``offsets[i]`` and ``lengths[i]`` index in *elements*, not bytes —
 *  the helper multiplies by ``bytesPerElement`` internally. */
+ (nullable NSArray<TTIOChannelSegment *> *)
    encryptChannelToSegments:(NSData *)plaintext
                      offsets:(const uint64_t *)offsets
                      lengths:(const uint32_t *)lengths
                     nSpectra:(NSUInteger)nSpectra
              bytesPerElement:(NSUInteger)bytesPerElement
                    datasetId:(uint16_t)datasetId
                  channelName:(NSString *)channelName
                          key:(NSData *)key
                        error:(NSError * _Nullable *)error;

/**
 * Decrypt every channel segment in order and concatenate the
 * plaintext float64 bytes.
 *
 * Convenience overload for the MS path (float64). Calls the
 * generalised method with `bytesPerElement = 8`.
 *
 * @param segments     Array of `TTIOChannelSegment` rows in AU order.
 * @param datasetId    Dataset identifier used to bind AAD during
 *                     encrypt.
 * @param channelName  Channel name used to bind AAD during encrypt.
 * @param key          32-byte AES-256-GCM key.
 * @param error        Out-error on GCM tag mismatch or length
 *                     validation failure.
 * @return Concatenated plaintext float64 bytes on success, or `nil`
 *         with `*error` set.
 */
+ (nullable NSData *)
    decryptChannelFromSegments:(NSArray<TTIOChannelSegment *> *)segments
                      datasetId:(uint16_t)datasetId
                    channelName:(NSString *)channelName
                            key:(NSData *)key
                          error:(NSError * _Nullable *)error;

/** Generalised decrypt — caller specifies the per-element byte
 *  width used to validate each segment's plaintext length. Default
 *  (8) preserves the MS path; pass 1 for the genomic uint8 path. */
+ (nullable NSData *)
    decryptChannelFromSegments:(NSArray<TTIOChannelSegment *> *)segments
              bytesPerElement:(NSUInteger)bytesPerElement
                      datasetId:(uint16_t)datasetId
                    channelName:(NSString *)channelName
                            key:(NSData *)key
                          error:(NSError * _Nullable *)error;


#pragma mark - Header segments (36 bytes)

/**
 * Pack a semantic header into the canonical 36-byte plaintext layout.
 *
 * Byte layout matches the cross-language packed-header spec so the
 * Python / Java packers produce identical bytes for the same field
 * values.
 *
 * @param header  Plaintext header fields.
 * @return 36-byte `NSData` ready to encrypt.
 */
+ (NSData *)packAUHeaderPlaintext:(TTIOAUHeaderPlaintext *)header;

/**
 * Unpack a 36-byte AU-header plaintext into typed fields.
 *
 * Inverse of `+packAUHeaderPlaintext:`.
 *
 * @param bytes  36-byte plaintext header (typically the output of
 *               header-segment decrypt).
 * @return Parsed `TTIOAUHeaderPlaintext` on success, or `nil` when
 *         `bytes.length != 36`.
 */
+ (nullable TTIOAUHeaderPlaintext *)unpackAUHeaderPlaintext:(NSData *)bytes;

/**
 * Encrypt a list of AU headers into per-row `TTIOHeaderSegment`s.
 *
 * Packs each `TTIOAUHeaderPlaintext` to its 36-byte canonical form
 * and encrypts it with a fresh random IV. AAD binds `datasetId` and
 * row index so segments cannot be replayed across datasets / AUs.
 *
 * @param rows       Per-spectrum plaintext headers in AU order.
 * @param datasetId  Dataset identifier (bound into AAD).
 * @param key        32-byte AES-256-GCM key.
 * @param error      Out-error on RNG / cipher failure.
 * @return Array of `TTIOHeaderSegment` rows on success, or `nil`
 *         with `*error` set.
 */
+ (nullable NSArray<TTIOHeaderSegment *> *)
    encryptHeaderSegments:(NSArray<TTIOAUHeaderPlaintext *> *)rows
                 datasetId:(uint16_t)datasetId
                       key:(NSData *)key
                     error:(NSError * _Nullable *)error;

/**
 * Inverse of `+encryptHeaderSegments:datasetId:key:error:`.
 *
 * Decrypts every header segment in order and unpacks each plaintext
 * back into a `TTIOAUHeaderPlaintext`. AAD is rebuilt from
 * `datasetId` and the row index so callers cannot accidentally
 * decrypt segments from a different dataset / AU.
 *
 * @param segments   Array of `TTIOHeaderSegment` rows in AU order.
 * @param datasetId  Dataset identifier used to bind AAD during encrypt.
 * @param key        32-byte AES-256-GCM key.
 * @param error      Out-error on GCM tag mismatch or unpacking failure.
 * @return Array of plaintext header records on success, or `nil` on
 *         any auth / unpack failure with `*error` set.
 */
+ (nullable NSArray<TTIOAUHeaderPlaintext *> *)
    decryptHeaderSegments:(NSArray<TTIOHeaderSegment *> *)segments
                 datasetId:(uint16_t)datasetId
                       key:(NSData *)key
                     error:(NSError * _Nullable *)error;

@end

NS_ASSUME_NONNULL_END

#endif
