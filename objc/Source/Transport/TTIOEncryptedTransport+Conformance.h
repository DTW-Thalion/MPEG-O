/*
 * TTIOEncryptedTransport+Conformance.h
 *
 * INTERNAL (not part of the public API). Exposes the FD-1 Phase A
 * recipient-block codec — otherwise file-static C functions — so the
 * Phase A-4 cross-language conformance test can pin their byte output
 * against the shared golden vectors in
 * conformance/multi_recipient/vectors.json.
 *
 * Each additional recipient is an NSDictionary with keys:
 *   @"recipientId"  -> NSString
 *   @"kekAlgorithm" -> NSString
 *   @"wrappedDek"   -> NSData
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "TTIOEncryptedTransport.h"

@interface TTIOEncryptedTransport (Conformance)

/** Encode the append-only trailing recipient block. Empty input ->
 *  empty data (single-recipient packets carry no trailing block). */
+ (NSData *)ttioConformanceEncodeRecipientBlock:(NSArray<NSDictionary *> *)additional;

/** Decode a standalone recipient block to an array of recipient dicts. */
+ (NSArray<NSDictionary *> *)ttioConformanceDecodeRecipientBlock:(NSData *)block;

/** FD-1 C-2a: encode the full trailing section after the five §4.4 fields
 *  (recipient block + optional server_kek_id) per the proven layout:
 *  emitted iff additional recipients OR a server_kek_id; a single-recipient
 *  server-processable container yields count=0 + server_kek_id. */
+ (NSData *)ttioConformanceEncodeTrailing:(NSArray<NSDictionary *> *)additional
                              serverKekId:(nullable NSString *)serverKekId;

@end
