/*
 * MPGOPerAUEncryption — v1.0 per-Access-Unit encryption primitives.
 *
 * Parallel to Python mpeg_o.encryption_per_au and Java
 * com.dtwthalion.mpgo.protection.PerAUEncryption. Implements the AAD
 * binding rules from docs/transport-spec.md §4.3.4 and the
 * <channel>_segments / au_header_segments compound layout from
 * docs/format-spec.md §9.1.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef MPGO_PER_AU_ENCRYPTION_H
#define MPGO_PER_AU_ENCRYPTION_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** One encrypted row of a ``<channel>_segments`` compound dataset. */
@interface MPGOChannelSegment : NSObject

@property (nonatomic, readonly) uint64_t offset;
@property (nonatomic, readonly) uint32_t length;
@property (nonatomic, readonly, strong) NSData *iv;         /* 12 bytes */
@property (nonatomic, readonly, strong) NSData *tag;        /* 16 bytes */
@property (nonatomic, readonly, strong) NSData *ciphertext;

- (instancetype)initWithOffset:(uint64_t)offset
                          length:(uint32_t)length
                              iv:(NSData *)iv
                             tag:(NSData *)tag
                      ciphertext:(NSData *)ciphertext;

@end


/** One encrypted row of ``spectrum_index/au_header_segments``. */
@interface MPGOHeaderSegment : NSObject

@property (nonatomic, readonly, strong) NSData *iv;         /* 12 bytes */
@property (nonatomic, readonly, strong) NSData *tag;        /* 16 bytes */
@property (nonatomic, readonly, strong) NSData *ciphertext; /* 36 bytes */

- (instancetype)initWithIV:(NSData *)iv
                        tag:(NSData *)tag
                 ciphertext:(NSData *)ciphertext;

@end


/** Plaintext form of the 36-byte AU semantic header. */
@interface MPGOAUHeaderPlaintext : NSObject

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
@interface MPGOPerAUEncryption : NSObject

#pragma mark - AAD

/** AAD for an encrypted channel payload:
 *  ``dataset_id (u16 LE) || au_sequence (u32 LE) || channel_name_utf8``. */
+ (NSData *)aadForChannel:(NSString *)channelName
                  datasetId:(uint16_t)datasetId
                 auSequence:(uint32_t)auSequence;

/** AAD for the encrypted semantic header. Appends literal ``b"header"``. */
+ (NSData *)aadForHeaderWithDatasetId:(uint16_t)datasetId
                             auSequence:(uint32_t)auSequence;

/** AAD for the encrypted pixel envelope. Appends literal ``b"pixel"``. */
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

/** AES-256-GCM decrypt + authenticate. Returns plaintext, or nil on
 *  tag mismatch / bad key / bad AAD. */
+ (nullable NSData *)decryptWithCiphertext:(NSData *)ciphertext
                                          key:(NSData *)key
                                           iv:(NSData *)iv
                                          tag:(NSData *)tag
                                          aad:(NSData *)aad
                                        error:(NSError * _Nullable *)error;

/** Generate a 12-byte cryptographically-random IV via OpenSSL RAND_bytes. */
+ (nullable NSData *)randomIVWithError:(NSError * _Nullable *)error;


#pragma mark - Channel segments

/** Slice ``plaintextFloat64`` into per-spectrum rows and encrypt each
 *  independently with a fresh IV. ``plaintextFloat64`` is a flat float64
 *  LE buffer; ``offsets[i]`` and ``lengths[i]`` index the i-th
 *  spectrum's slice. */
+ (nullable NSArray<MPGOChannelSegment *> *)
    encryptChannelToSegments:(NSData *)plaintextFloat64
                      offsets:(const uint64_t *)offsets
                      lengths:(const uint32_t *)lengths
                     nSpectra:(NSUInteger)nSpectra
                    datasetId:(uint16_t)datasetId
                  channelName:(NSString *)channelName
                          key:(NSData *)key
                        error:(NSError * _Nullable *)error;

/** Decrypt every row in order and concatenate plaintext float64 bytes. */
+ (nullable NSData *)
    decryptChannelFromSegments:(NSArray<MPGOChannelSegment *> *)segments
                      datasetId:(uint16_t)datasetId
                    channelName:(NSString *)channelName
                            key:(NSData *)key
                          error:(NSError * _Nullable *)error;


#pragma mark - Header segments (36 bytes)

/** Pack the semantic header into the canonical 36-byte plaintext. */
+ (NSData *)packAUHeaderPlaintext:(MPGOAUHeaderPlaintext *)header;

/** Inverse of +packAUHeaderPlaintext. Returns nil if data is not 36 bytes. */
+ (nullable MPGOAUHeaderPlaintext *)unpackAUHeaderPlaintext:(NSData *)bytes;

/** Encrypt one MPGOAUHeaderPlaintext per spectrum into HeaderSegments. */
+ (nullable NSArray<MPGOHeaderSegment *> *)
    encryptHeaderSegments:(NSArray<MPGOAUHeaderPlaintext *> *)rows
                 datasetId:(uint16_t)datasetId
                       key:(NSData *)key
                     error:(NSError * _Nullable *)error;

+ (nullable NSArray<MPGOAUHeaderPlaintext *> *)
    decryptHeaderSegments:(NSArray<MPGOHeaderSegment *> *)segments
                 datasetId:(uint16_t)datasetId
                       key:(NSData *)key
                     error:(NSError * _Nullable *)error;

@end

NS_ASSUME_NONNULL_END

#endif
