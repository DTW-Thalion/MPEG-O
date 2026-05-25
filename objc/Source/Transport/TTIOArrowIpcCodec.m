/*
 * TTIOArrowIpcCodec.m
 * TTI-O Objective-C Implementation
 *
 * Stateless Arrow IPC encoder/decoder for transport-spec v0.11 tabular
 * payloads -- IDENTIFICATIONS_TABLE (0x16) and QUANTIFICATIONS_TABLE
 * (0x17).
 *
 * This file is pure Objective-C. The libarrow C++ work happens in
 * TTIOArrowIpcBridge.mm, reached through the two `extern "C"`
 * symbols TTIOArrowIpcEncode + TTIOArrowIpcDecode declared below.
 *
 * Cross-language equivalents:
 *   Java:   global.thalion.ttio.transport.ArrowIpcCodec
 *   Python: ttio.transport.arrow_ipc
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "TTIOArrowIpcCodec.h"
#import "Dataset/TTIOIdentification.h"
#import "Dataset/TTIOQuantification.h"

/* Bridge entry points (TTIOArrowIpcBridge.mm). */
extern NSData    *TTIOArrowIpcEncode(NSString *schemaName, NSString *rowsJson);
extern NSString  *TTIOArrowIpcDecode(NSString *schemaName, NSData   *ipc);

/* Compact JSON array of strings, matching Java's emit format
 * (no whitespace, double-quoted, NSJSONWritingSortedKeys is irrelevant
 * for arrays). Empty array serialises to "[]". */
static NSString *EvidenceChainToJson(NSArray<NSString *> *evidence)
{
    if (!evidence || evidence.count == 0) return @"[]";
    NSError *err = nil;
    NSData *d = [NSJSONSerialization dataWithJSONObject:evidence
                                                options:0
                                                  error:&err];
    if (!d) return @"[]";
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"[]";
}

/* Inverse: parse Java/Python-compatible JSON array of strings to
 * NSArray. Tolerates empty / nil / "[]" and bad inputs (returns @[]). */
static NSArray<NSString *> *EvidenceChainFromJson(NSString *json)
{
    if (!json || json.length == 0) return @[];
    NSData *d = [json dataUsingEncoding:NSUTF8StringEncoding];
    if (!d) return @[];
    NSError *err = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:d options:0 error:&err];
    if (!parsed || ![parsed isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:[parsed count]];
    for (id item in (NSArray *)parsed) {
        if ([item isKindOfClass:[NSString class]]) {
            [out addObject:(NSString *)item];
        } else if (item != [NSNull null]) {
            [out addObject:[item description]];
        }
    }
    return [out copy];
}

@implementation TTIOArrowIpcCodec

// =====================================================================
//  Identifications (packet 0x16)
// =====================================================================

+ (NSData *)encodeIdentifications:(NSArray<TTIOIdentification *> *)rows
{
    NSMutableArray<NSDictionary *> *jsonRows =
        [NSMutableArray arrayWithCapacity:rows.count];
    for (TTIOIdentification *r in rows) {
        // spectrum_index is int32 in the Arrow schema (Java + Python).
        // ObjC's NSUInteger is 64-bit on x86_64; clamp to int32 range
        // for parity. Real inputs are spectrum indices within an
        // acquisition run, far below 2^31.
        NSNumber *idx = @((int32_t)r.spectrumIndex);
        [jsonRows addObject:@{
            @"run_name":            r.runName ?: @"",
            @"spectrum_index":      idx,
            @"chemical_entity":     r.chemicalEntity ?: @"",
            @"confidence_score":    @(r.confidenceScore),
            @"evidence_chain_json": EvidenceChainToJson(r.evidenceChain),
        }];
    }
    NSError *jsonErr = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:jsonRows
                                                       options:0
                                                         error:&jsonErr];
    if (!jsonData) {
        [NSException raise:NSInvalidArgumentException
                    format:@"TTIOArrowIpcCodec: encode JSON build failed: %@", jsonErr];
    }
    NSString *jsonStr = [[NSString alloc] initWithData:jsonData
                                              encoding:NSUTF8StringEncoding];
    NSData *out = TTIOArrowIpcEncode(@"identifications", jsonStr);
    if (!out) {
        [NSException raise:NSGenericException
                    format:@"TTIOArrowIpcCodec: Arrow IPC encode (identifications) failed"];
    }
    return out;
}

+ (NSArray<TTIOIdentification *> *)decodeIdentifications:(NSData *)ipc
{
    if (!ipc || ipc.length == 0) return @[];
    NSString *rowsJson = TTIOArrowIpcDecode(@"identifications", ipc);
    if (!rowsJson) {
        [NSException raise:NSGenericException
                    format:@"TTIOArrowIpcCodec: Arrow IPC decode (identifications) failed"];
    }
    NSData *jsonData = [rowsJson dataUsingEncoding:NSUTF8StringEncoding];
    NSError *jsonErr = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:jsonData
                                                options:0
                                                  error:&jsonErr];
    if (!parsed || ![parsed isKindOfClass:[NSArray class]]) {
        [NSException raise:NSGenericException
                    format:@"TTIOArrowIpcCodec: decode JSON parse failed: %@", jsonErr];
    }
    NSArray<NSDictionary *> *rows = (NSArray<NSDictionary *> *)parsed;
    NSMutableArray<TTIOIdentification *> *out =
        [NSMutableArray arrayWithCapacity:rows.count];
    for (NSDictionary *r in rows) {
        NSNumber *idx = r[@"spectrum_index"];
        NSNumber *score = r[@"confidence_score"];
        NSArray<NSString *> *evidence =
            EvidenceChainFromJson(r[@"evidence_chain_json"]);
        TTIOIdentification *ident = [[TTIOIdentification alloc]
            initWithRunName:(r[@"run_name"] ?: @"")
              spectrumIndex:(NSUInteger)[idx unsignedIntegerValue]
             chemicalEntity:(r[@"chemical_entity"] ?: @"")
            confidenceScore:[score doubleValue]
              evidenceChain:evidence];
        [out addObject:ident];
    }
    return [out copy];
}

// =====================================================================
//  Quantifications (packet 0x17)
// =====================================================================

+ (NSData *)encodeQuantifications:(NSArray<TTIOQuantification *> *)rows
{
    NSMutableArray<NSDictionary *> *jsonRows =
        [NSMutableArray arrayWithCapacity:rows.count];
    for (TTIOQuantification *r in rows) {
        [jsonRows addObject:@{
            @"chemical_entity":      r.chemicalEntity ?: @"",
            @"sample_ref":           r.sampleRef ?: @"",
            @"abundance":            @(r.abundance),
            @"normalization_method": r.normalizationMethod ?: @"",
            @"unit":                 r.unit ?: @"",
        }];
    }
    NSError *jsonErr = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:jsonRows
                                                       options:0
                                                         error:&jsonErr];
    if (!jsonData) {
        [NSException raise:NSInvalidArgumentException
                    format:@"TTIOArrowIpcCodec: encode JSON build failed: %@", jsonErr];
    }
    NSString *jsonStr = [[NSString alloc] initWithData:jsonData
                                              encoding:NSUTF8StringEncoding];
    NSData *out = TTIOArrowIpcEncode(@"quantifications", jsonStr);
    if (!out) {
        [NSException raise:NSGenericException
                    format:@"TTIOArrowIpcCodec: Arrow IPC encode (quantifications) failed"];
    }
    return out;
}

+ (NSArray<TTIOQuantification *> *)decodeQuantifications:(NSData *)ipc
{
    if (!ipc || ipc.length == 0) return @[];
    NSString *rowsJson = TTIOArrowIpcDecode(@"quantifications", ipc);
    if (!rowsJson) {
        [NSException raise:NSGenericException
                    format:@"TTIOArrowIpcCodec: Arrow IPC decode (quantifications) failed"];
    }
    NSData *jsonData = [rowsJson dataUsingEncoding:NSUTF8StringEncoding];
    NSError *jsonErr = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:jsonData
                                                options:0
                                                  error:&jsonErr];
    if (!parsed || ![parsed isKindOfClass:[NSArray class]]) {
        [NSException raise:NSGenericException
                    format:@"TTIOArrowIpcCodec: decode JSON parse failed: %@", jsonErr];
    }
    NSArray<NSDictionary *> *rows = (NSArray<NSDictionary *> *)parsed;
    NSMutableArray<TTIOQuantification *> *out =
        [NSMutableArray arrayWithCapacity:rows.count];
    for (NSDictionary *r in rows) {
        NSNumber *abundance = r[@"abundance"];
        TTIOQuantification *q = [[TTIOQuantification alloc]
            initWithChemicalEntity:(r[@"chemical_entity"] ?: @"")
                         sampleRef:(r[@"sample_ref"] ?: @"")
                         abundance:[abundance doubleValue]
               normalizationMethod:(r[@"normalization_method"] ?: @"")
                              unit:(r[@"unit"] ?: @"")];
        [out addObject:q];
    }
    return [out copy];
}

@end
