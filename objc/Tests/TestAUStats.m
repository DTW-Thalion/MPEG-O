/*
 * TestAUStats — TTIOAUStats per-AccessUnit summary stats.
 *
 * Cross-language equivalents:
 *   python/tests/test_au_stats.py
 *   java/src/test/java/global/thalion/ttio/transport/AUStatsTest.java
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <math.h>

#import "Transport/TTIOAUStats.h"
#import "Transport/TTIOAccessUnit.h"

static TTIOAccessUnit *msAU(void)
{
    TTIOTransportChannelData *c1 =
        [[TTIOTransportChannelData alloc]
            initWithName:@"mz" precision:3 compression:0
               nElements:1024
                    data:[NSMutableData dataWithLength:4096]];
    TTIOTransportChannelData *c2 =
        [[TTIOTransportChannelData alloc]
            initWithName:@"intensity" precision:3 compression:0
               nElements:1024
                    data:[NSMutableData dataWithLength:4096]];
    return [[TTIOAccessUnit alloc]
        initWithSpectrumClass:0 acquisitionMode:0 msLevel:2
                     polarity:1 retentionTime:12.5 precursorMz:400.5
              precursorCharge:2 ionMobility:0.0
            basePeakIntensity:98765.0
                     channels:@[c1, c2]
                       pixelX:0 pixelY:0 pixelZ:0];
}

static TTIOAccessUnit *genomicAU(void)
{
    TTIOTransportChannelData *seq =
        [[TTIOTransportChannelData alloc]
            initWithName:@"seq" precision:0 compression:0
               nElements:150
                    data:[NSMutableData dataWithLength:150]];
    TTIOTransportChannelData *qual =
        [[TTIOTransportChannelData alloc]
            initWithName:@"qual" precision:0 compression:0
               nElements:150
                    data:[NSMutableData dataWithLength:150]];
    TTIOTransportChannelData *cigar =
        [[TTIOTransportChannelData alloc]
            initWithName:@"cigar" precision:0 compression:0
               nElements:10
                    data:[NSMutableData dataWithLength:12]];
    return [[TTIOAccessUnit alloc]
        initWithSpectrumClass:5 acquisitionMode:0 msLevel:0
                     polarity:2 retentionTime:0.0 precursorMz:0.0
              precursorCharge:0 ionMobility:0.0
            basePeakIntensity:0.0
                     channels:@[seq, qual, cigar]
                       pixelX:0 pixelY:0 pixelZ:0
                   chromosome:@"chr3" position:12345678
               mappingQuality:60 flags:99];
}

static TTIOAccessUnit *imageAU(void)
{
    TTIOTransportChannelData *c1 =
        [[TTIOTransportChannelData alloc]
            initWithName:@"mz" precision:3 compression:0
               nElements:512
                    data:[NSMutableData dataWithLength:2048]];
    return [[TTIOAccessUnit alloc]
        initWithSpectrumClass:4 acquisitionMode:0 msLevel:1
                     polarity:0 retentionTime:0.0 precursorMz:0.0
              precursorCharge:0 ionMobility:0.0
            basePeakIntensity:0.0
                     channels:@[c1]
                       pixelX:7 pixelY:11 pixelZ:13];
}

void testAUStats(void)
{
    @autoreleasepool {
        // ── 1. MS AU fields ────────────────────────────────────────
        {
            TTIOAUStats *s = [TTIOAUStats statsForAccessUnit:msAU()
                                                 auSequence:42];
            PASS(s.auSequence == 42, "MS: au_sequence preserved");
            PASS(s.spectrumClass == 0, "MS: spectrum_class = 0");
            PASS(s.msLevel == 2, "MS: ms_level preserved");
            PASS(s.polarity == 1, "MS: polarity preserved");
            PASS(fabs(s.retentionTime - 12.5) < 1e-9,
                 "MS: retention_time preserved");
            PASS(fabs(s.precursorMz - 400.5) < 1e-9,
                 "MS: precursor_mz preserved");
            PASS(s.precursorCharge == 2, "MS: precursor_charge preserved");
            PASS(fabs(s.basePeakIntensity - 98765.0) < 1e-9,
                 "MS: base_peak_intensity preserved");
            PASS(s.channelCount == 2, "MS: channel_count = 2");
            PASS(s.totalElements == 2048,
                 "MS: total_elements = sum of nElements");
            PASS(s.payloadBytes == 8192,
                 "MS: payload_bytes = sum of channel data length");
            PASS(s.chromosome == nil, "MS: chromosome is nil");
            PASS(s.position == 0, "MS: position is 0");
            PASS(s.pixelX == 0 && s.pixelY == 0 && s.pixelZ == 0,
                 "MS: pixel_* fields zero");
        }

        // ── 2. Genomic AU fields ───────────────────────────────────
        {
            TTIOAUStats *s = [TTIOAUStats statsForAccessUnit:genomicAU()
                                                 auSequence:7];
            PASS(s.spectrumClass == 5, "Genomic: spectrum_class = 5");
            PASS([s.chromosome isEqualToString:@"chr3"],
                 "Genomic: chromosome preserved");
            PASS(s.position == 12345678, "Genomic: position preserved");
            PASS(s.mappingQuality == 60,
                 "Genomic: mapping_quality preserved");
            PASS(s.flags == 99, "Genomic: flags preserved");
            PASS(s.channelCount == 3, "Genomic: channel_count = 3");
            PASS(s.totalElements == 310,
                 "Genomic: total_elements 150+150+10");
            PASS(s.payloadBytes == 312,
                 "Genomic: payload_bytes 150+150+12");
        }

        // ── 3. Image AU fields ─────────────────────────────────────
        {
            TTIOAUStats *s = [TTIOAUStats statsForAccessUnit:imageAU()
                                                 auSequence:3];
            PASS(s.spectrumClass == 4, "Image: spectrum_class = 4");
            PASS(s.pixelX == 7 && s.pixelY == 11 && s.pixelZ == 13,
                 "Image: pixel_* coords preserved");
        }

        // ── 4. JSON dict shape: MS excludes genomic + image keys ──
        {
            TTIOAUStats *s = [TTIOAUStats statsForAccessUnit:msAU()
                                                 auSequence:1];
            NSDictionary *d = [s JSONDictionary];
            PASS(d[@"chromosome"] == nil, "MS JSON: no chromosome key");
            PASS(d[@"position"] == nil, "MS JSON: no position key");
            PASS(d[@"pixel_x"] == nil, "MS JSON: no pixel_x key");
            PASS([d[@"au_sequence"] integerValue] == 1,
                 "MS JSON: au_sequence present");
            PASS([d[@"channel_count"] integerValue] == 2,
                 "MS JSON: channel_count present");
        }

        // ── 5. JSON dict shape: genomic includes genomic keys ──────
        {
            TTIOAUStats *s = [TTIOAUStats statsForAccessUnit:genomicAU()
                                                 auSequence:7];
            NSDictionary *d = [s JSONDictionary];
            PASS([d[@"chromosome"] isEqualToString:@"chr3"],
                 "Genomic JSON: chromosome key present + correct");
            PASS([d[@"position"] longLongValue] == 12345678LL,
                 "Genomic JSON: position key present");
            PASS([d[@"mapping_quality"] integerValue] == 60,
                 "Genomic JSON: mapping_quality key present");
            PASS([d[@"flags"] integerValue] == 99,
                 "Genomic JSON: flags key present");
            PASS(d[@"pixel_x"] == nil,
                 "Genomic JSON: no pixel_x key");
        }

        // ── 6. JSON dict shape: image includes image keys ──────────
        {
            TTIOAUStats *s = [TTIOAUStats statsForAccessUnit:imageAU()
                                                 auSequence:3];
            NSDictionary *d = [s JSONDictionary];
            PASS([d[@"pixel_x"] integerValue] == 7,
                 "Image JSON: pixel_x key present");
            PASS([d[@"pixel_y"] integerValue] == 11,
                 "Image JSON: pixel_y key present");
            PASS([d[@"pixel_z"] integerValue] == 13,
                 "Image JSON: pixel_z key present");
            PASS(d[@"chromosome"] == nil,
                 "Image JSON: no chromosome key");
        }

        // ── 7. JSON string: compact + sorted keys ──────────────────
        {
            NSString *j = [TTIOAUStats JSONStringForAccessUnit:msAU()
                                                    auSequence:42];
            PASS(j != nil, "JSON string produced");
            PASS([j rangeOfString:@" "].location == NSNotFound,
                 "JSON: no whitespace (compact)");
            NSRange auR  = [j rangeOfString:@"au_sequence"];
            NSRange bpiR = [j rangeOfString:@"base_peak_intensity"];
            NSRange ccR  = [j rangeOfString:@"channel_count"];
            PASS(auR.location < bpiR.location,
                 "JSON: au_sequence before base_peak_intensity");
            PASS(bpiR.location < ccR.location,
                 "JSON: base_peak_intensity before channel_count");
        }
    }
}
