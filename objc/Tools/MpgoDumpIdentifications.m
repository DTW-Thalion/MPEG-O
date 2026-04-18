/*
 * MpgoDumpIdentifications — v0.7 M51 compound parity dumper.
 *
 * Reads an .mpgo file and emits the dataset-wide identifications,
 * quantifications, and provenance records as deterministic JSON to
 * stdout. Byte-identical to the Python
 * ``mpeg_o.tools.dump_identifications`` module and the Java
 * ``DumpIdentifications`` class.
 *
 * Build via gnustep-make (see GNUmakefile).
 * Usage: MpgoDumpIdentifications <path-to-.mpgo>
 *
 * Exit codes:
 *   0  wrote output successfully
 *   1  argument error
 *   2  open/read failure
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

#import "Dataset/MPGOSpectralDataset.h"
#import "Dataset/MPGOIdentification.h"
#import "Dataset/MPGOQuantification.h"
#import "Dataset/MPGOProvenanceRecord.h"

#pragma mark - Canonical JSON emitter

/** JSON-escape @c s. Backslash-escapes the two reserved JSON chars
 *  plus the C0 control classics; C0 non-classics are emitted as
 *  \uXXXX. Raw UTF-8 is preserved for everything else (matches
 *  Python's @c ensure_ascii=False and Java's equivalent). */
static NSString *escapeString(NSString *s)
{
    NSMutableString *out = [NSMutableString stringWithCapacity:s.length + 2];
    [out appendString:@"\""];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar ch = [s characterAtIndex:i];
        switch (ch) {
            case '"':  [out appendString:@"\\\""]; break;
            case '\\': [out appendString:@"\\\\"]; break;
            case '\b': [out appendString:@"\\b"]; break;
            case '\f': [out appendString:@"\\f"]; break;
            case '\n': [out appendString:@"\\n"]; break;
            case '\r': [out appendString:@"\\r"]; break;
            case '\t': [out appendString:@"\\t"]; break;
            default:
                if (ch < 0x20) {
                    [out appendFormat:@"\\u%04x", (unsigned)ch];
                } else {
                    [out appendFormat:@"%C", ch];
                }
                break;
        }
    }
    [out appendString:@"\""];
    return out;
}

/** C99 %.17g via NSString's stringWithFormat. */
static NSString *formatFloat(double x)
{
    if (isnan(x)) return @"nan";
    if (isinf(x)) return x < 0 ? @"-inf" : @"inf";
    return [NSString stringWithFormat:@"%.17g", x];
}

static NSString *formatInt(long long x)
{
    return [NSString stringWithFormat:@"%lld", x];
}

static NSString *formatValue(id v);

static NSString *formatList(NSArray *a)
{
    NSMutableString *out = [NSMutableString stringWithString:@"["];
    for (NSUInteger i = 0; i < a.count; i++) {
        if (i > 0) [out appendString:@","];
        [out appendString:formatValue(a[i])];
    }
    [out appendString:@"]"];
    return out;
}

static NSString *formatDict(NSDictionary *d)
{
    NSArray *keys =
        [d.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSMutableString *out = [NSMutableString stringWithString:@"{"];
    for (NSUInteger i = 0; i < keys.count; i++) {
        if (i > 0) [out appendString:@","];
        NSString *k = keys[i];
        [out appendString:escapeString(k)];
        [out appendString:@":"];
        [out appendString:formatValue(d[k])];
    }
    [out appendString:@"}"];
    return out;
}

static NSString *formatValue(id v)
{
    if (v == nil || v == [NSNull null]) return @"null";
    if ([v isKindOfClass:[NSString class]]) {
        return escapeString(v);
    }
    if ([v isKindOfClass:[NSArray class]]) {
        return formatList(v);
    }
    if ([v isKindOfClass:[NSDictionary class]]) {
        return formatDict(v);
    }
    if ([v isKindOfClass:[NSNumber class]]) {
        NSNumber *n = v;
        const char *t = n.objCType;
        // Float types: 'f' or 'd'. Everything else we treat as integer.
        if (strcmp(t, "d") == 0 || strcmp(t, "f") == 0) {
            return formatFloat(n.doubleValue);
        }
        // Bools come through as NSNumber with objCType 'c' (BOOL) or 'B'.
        // MPGO compound records don't carry booleans today; encode as
        // integer to match the Python fallback.
        return formatInt(n.longLongValue);
    }
    [NSException raise:@"MPGOCanonicalJSONError"
                format:@"unsupported canonical JSON value: %@",
                       NSStringFromClass([v class])];
    return nil;
}

/** Top-level M51 dump shape. */
static NSString *formatTopLevel(NSDictionary<NSString *, NSArray *> *sections)
{
    NSArray *keys =
        [sections.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSMutableString *out = [NSMutableString stringWithString:@"{"];
    BOOL firstSection = YES;
    for (NSString *key in keys) {
        if (!firstSection) [out appendString:@","];
        firstSection = NO;
        [out appendString:@"\n"];
        [out appendString:escapeString(key)];
        [out appendString:@": ["];
        NSArray *records = sections[key];
        for (NSUInteger i = 0; i < records.count; i++) {
            [out appendString:@"\n"];
            [out appendString:formatValue(records[i])];
            if (i < records.count - 1) [out appendString:@","];
        }
        if (records.count > 0) [out appendString:@"\n"];
        [out appendString:@"]"];
    }
    [out appendString:@"\n}\n"];
    return out;
}

#pragma mark - Record builders

static NSDictionary *identificationRecord(MPGOIdentification *i)
{
    return @{
        @"chemical_entity":   i.chemicalEntity ?: @"",
        @"confidence_score":  @(i.confidenceScore),
        @"evidence_chain":    i.evidenceChain ?: @[],
        @"run_name":          i.runName ?: @"",
        @"spectrum_index":    @((long long)i.spectrumIndex),
    };
}

static NSDictionary *quantificationRecord(MPGOQuantification *q)
{
    return @{
        @"abundance":            @(q.abundance),
        @"chemical_entity":      q.chemicalEntity ?: @"",
        @"normalization_method": q.normalizationMethod ?: @"",
        @"sample_ref":           q.sampleRef ?: @"",
    };
}

static NSDictionary *provenanceRecord(MPGOProvenanceRecord *p)
{
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    NSDictionary *src = p.parameters ?: @{};
    for (NSString *k in src) {
        id v = src[k];
        params[k] = [v isKindOfClass:[NSString class]] ? v
                                                        : [v description];
    }
    return @{
        @"input_refs":      p.inputRefs ?: @[],
        @"output_refs":     p.outputRefs ?: @[],
        @"parameters":      params,
        @"software":        p.software ?: @"",
        @"timestamp_unix":  @((long long)p.timestampUnix),
    };
}

#pragma mark - Main

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr,
                "usage: %s <path.mpgo>\n", argv[0]);
            return 1;
        }
        NSString *path = @(argv[1]);

        NSError *error = nil;
        MPGOSpectralDataset *ds =
            [MPGOSpectralDataset readFromFilePath:path error:&error];
        if (ds == nil) {
            fprintf(stderr, "open failed: %s\n",
                    error.localizedDescription.UTF8String);
            return 2;
        }

        NSMutableArray *idents = [NSMutableArray array];
        for (MPGOIdentification *i in ds.identifications) {
            [idents addObject:identificationRecord(i)];
        }
        NSMutableArray *quants = [NSMutableArray array];
        for (MPGOQuantification *q in ds.quantifications) {
            [quants addObject:quantificationRecord(q)];
        }
        NSMutableArray *provs = [NSMutableArray array];
        for (MPGOProvenanceRecord *p in ds.provenanceRecords) {
            [provs addObject:provenanceRecord(p)];
        }
        [ds closeFile];

        NSString *blob = formatTopLevel(@{
            @"identifications": idents,
            @"quantifications": quants,
            @"provenance":      provs,
        });
        NSData *utf8 = [blob dataUsingEncoding:NSUTF8StringEncoding];
        fwrite(utf8.bytes, 1, utf8.length, stdout);
        fflush(stdout);
        return 0;
    }
}
