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
#import "Dataset/TTIOSubject.h"
#import "Dataset/TTIOSample.h"

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

// =====================================================================
//  Subjects (packet 0x19, Stage 6 / transport-spec §4.22)
// =====================================================================
//
// Null convention (cross-lang with Java + Python):
//   - Optional strings project + sex: empty-string @"" -> Arrow null
//     on the wire; decoded back to @"" on read.
//   - birth_year: sentinel 0 -> Arrow null on the wire; decoded back
//     to 0 on read.
//   - external_id is notNullable; attributes_json is always present
//     (@"{}" for empty maps).
// All three transformations live in TTIOArrowIpcBridge.mm
// (ShouldNullOnEmptyString + ShouldNullOnZero); the codec just
// marshals NSDictionary rows to/from JSON.

+ (NSData *)encodeSubjects:(NSArray<TTIOSubject *> *)rows
{
    NSMutableArray<NSDictionary *> *jsonRows =
        [NSMutableArray arrayWithCapacity:rows.count];
    for (TTIOSubject *r in rows) {
        // birth_year is int32 on the wire (column-width consistency
        // with the identification table, see design spec §6.1).
        NSNumber *by = @((int32_t)r.birthYear);
        [jsonRows addObject:@{
            @"external_id":     r.externalId ?: @"",
            @"project":         r.project ?: @"",
            @"sex":             r.sex ?: @"",
            @"birth_year":      by,
            @"attributes_json": [r attributesJson] ?: @"{}",
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
    NSData *out = TTIOArrowIpcEncode(@"subjects", jsonStr);
    if (!out) {
        [NSException raise:NSGenericException
                    format:@"TTIOArrowIpcCodec: Arrow IPC encode (subjects) failed"];
    }
    return out;
}

+ (NSArray<TTIOSubject *> *)decodeSubjects:(NSData *)ipc
{
    if (!ipc || ipc.length == 0) return @[];
    NSString *rowsJson = TTIOArrowIpcDecode(@"subjects", ipc);
    if (!rowsJson) {
        [NSException raise:NSGenericException
                    format:@"TTIOArrowIpcCodec: Arrow IPC decode (subjects) failed"];
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
    NSMutableArray<TTIOSubject *> *out =
        [NSMutableArray arrayWithCapacity:rows.count];
    for (NSDictionary *r in rows) {
        NSNumber *by = r[@"birth_year"];
        NSString *attrsJson = r[@"attributes_json"];
        if (![attrsJson isKindOfClass:[NSString class]]) attrsJson = @"{}";
        NSDictionary<NSString *, NSString *> *attrs =
            [self _parseAttributesJsonForCodec:attrsJson];
        TTIOSubject *s = [[TTIOSubject alloc]
            initWithExternalId:(r[@"external_id"] ?: @"")
                        project:(r[@"project"] ?: @"")
                            sex:(r[@"sex"] ?: @"")
                      birthYear:(int64_t)[by longLongValue]
                     attributes:attrs];
        [out addObject:s];
    }
    return [out copy];
}

// =====================================================================
//  Samples (packet 0x1A, Stage 6 / transport-spec §4.22)
// =====================================================================

+ (NSData *)encodeSamples:(NSArray<TTIOSample *> *)rows
{
    NSMutableArray<NSDictionary *> *jsonRows =
        [NSMutableArray arrayWithCapacity:rows.count];
    for (TTIOSample *r in rows) {
        // collected_at is int64 on the wire (Unix seconds since epoch).
        NSNumber *ts = @((long long)r.collectedAt);
        [jsonRows addObject:@{
            @"sample_id":           r.sampleId ?: @"",
            @"subject_external_id": r.subjectExternalId ?: @"",
            @"sample_kind":         r.sampleKind ?: @"",
            @"collected_at":        ts,
            @"attributes_json":     [r attributesJson] ?: @"{}",
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
    NSData *out = TTIOArrowIpcEncode(@"samples", jsonStr);
    if (!out) {
        [NSException raise:NSGenericException
                    format:@"TTIOArrowIpcCodec: Arrow IPC encode (samples) failed"];
    }
    return out;
}

+ (NSArray<TTIOSample *> *)decodeSamples:(NSData *)ipc
{
    if (!ipc || ipc.length == 0) return @[];
    NSString *rowsJson = TTIOArrowIpcDecode(@"samples", ipc);
    if (!rowsJson) {
        [NSException raise:NSGenericException
                    format:@"TTIOArrowIpcCodec: Arrow IPC decode (samples) failed"];
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
    NSMutableArray<TTIOSample *> *out =
        [NSMutableArray arrayWithCapacity:rows.count];
    for (NSDictionary *r in rows) {
        NSNumber *ts = r[@"collected_at"];
        NSString *attrsJson = r[@"attributes_json"];
        if (![attrsJson isKindOfClass:[NSString class]]) attrsJson = @"{}";
        NSDictionary<NSString *, NSString *> *attrs =
            [self _parseAttributesJsonForCodec:attrsJson];
        TTIOSample *s = [[TTIOSample alloc]
            initWithSampleId:(r[@"sample_id"] ?: @"")
           subjectExternalId:(r[@"subject_external_id"] ?: @"")
                  sampleKind:(r[@"sample_kind"] ?: @"")
                 collectedAt:(int64_t)[ts longLongValue]
                  attributes:attrs];
        [out addObject:s];
    }
    return [out copy];
}

// Decode attributes_json into a string-keyed/string-valued dict.
// "{}" and the empty string both round-trip to @{}.
+ (NSDictionary<NSString *, NSString *> *)
    _parseAttributesJsonForCodec:(NSString *)blob
{
    if (blob == nil || blob.length == 0 || [blob isEqualToString:@"{}"]) {
        return @{};
    }
    NSData *data = [blob dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil) return @{};
    NSError *err = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data
                                                options:0
                                                  error:&err];
    if (![parsed isKindOfClass:[NSDictionary class]]) return @{};
    NSMutableDictionary<NSString *, NSString *> *out =
        [NSMutableDictionary dictionaryWithCapacity:[parsed count]];
    for (id key in (NSDictionary *)parsed) {
        if (![key isKindOfClass:[NSString class]]) continue;
        id v = ((NSDictionary *)parsed)[key];
        if ([v isKindOfClass:[NSString class]]) {
            out[(NSString *)key] = (NSString *)v;
        } else if (v != [NSNull null]) {
            out[(NSString *)key] = [v description];
        }
    }
    return [out copy];
}

@end
