/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "Run/TTIOWrittenSpectralBatch.h"
#import "Spectra/TTIOSpectrum.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "ValueClasses/TTIOIsolationWindow.h"
#import "ValueClasses/TTIOEnums.h"

@implementation TTIOWrittenSpectralBatch

- (instancetype)initWithOffsets:(NSData *)offsets
                        lengths:(NSData *)lengths
                 retentionTimes:(NSData *)retentionTimes
                       msLevels:(NSData *)msLevels
                     polarities:(NSData *)polarities
                   precursorMzs:(NSData *)precursorMzs
               precursorCharges:(NSData *)precursorCharges
            basePeakIntensities:(NSData *)basePeakIntensities
              activationMethods:(NSData *)activationMethods
             isolationTargetMzs:(NSData *)isolationTargetMzs
          isolationLowerOffsets:(NSData *)isolationLowerOffsets
          isolationUpperOffsets:(NSData *)isolationUpperOffsets
                    centroideds:(NSData *)centroideds
                    channelData:(NSDictionary<NSString *, NSData *> *)channelData
{
    self = [super init];
    if (self) {
        _offsets = [offsets copy] ?: [NSData data];
        _lengths = [lengths copy] ?: [NSData data];
        _retentionTimes = [retentionTimes copy] ?: [NSData data];
        _msLevels = [msLevels copy] ?: [NSData data];
        _polarities = [polarities copy] ?: [NSData data];
        _precursorMzs = [precursorMzs copy] ?: [NSData data];
        _precursorCharges = [precursorCharges copy] ?: [NSData data];
        _basePeakIntensities = [basePeakIntensities copy] ?: [NSData data];
        _activationMethods = [activationMethods copy];
        _isolationTargetMzs = [isolationTargetMzs copy];
        _isolationLowerOffsets = [isolationLowerOffsets copy];
        _isolationUpperOffsets = [isolationUpperOffsets copy];
        _centroideds = [centroideds copy];
        _channelData = [channelData copy] ?: @{};
    }
    return self;
}

- (NSUInteger)spectrumCount { return _lengths.length / sizeof(uint32_t); }
- (BOOL)hasM74 { return _activationMethods != nil; }

+ (instancetype)batchWithSpectra:(NSArray<TTIOSpectrum *> *)spectra
                    channelNames:(NSArray<NSString *> *)channelNames
{
    NSUInteger n = spectra.count;
    NSMutableData *offsets = [NSMutableData dataWithLength:n * sizeof(uint64_t)];
    NSMutableData *lengths = [NSMutableData dataWithLength:n * sizeof(uint32_t)];
    NSMutableData *rts = [NSMutableData dataWithLength:n * sizeof(double)];
    NSMutableData *ml = [NSMutableData dataWithLength:n * sizeof(int32_t)];
    NSMutableData *pol = [NSMutableData dataWithLength:n * sizeof(int32_t)];
    NSMutableData *pmz = [NSMutableData dataWithLength:n * sizeof(double)];
    NSMutableData *pc = [NSMutableData dataWithLength:n * sizeof(int32_t)];
    NSMutableData *bp = [NSMutableData dataWithLength:n * sizeof(double)];
    uint64_t *off = offsets.mutableBytes;
    uint32_t *len = lengths.mutableBytes;
    double *rt = rts.mutableBytes;
    int32_t *mlp = ml.mutableBytes;
    int32_t *plp = pol.mutableBytes;
    double *pmp = pmz.mutableBytes;
    int32_t *pcp = pc.mutableBytes;
    double *bpp = bp.mutableBytes;

    BOOL anyM74 = NO;
    for (TTIOSpectrum *s in spectra) {
        if (![s isKindOfClass:[TTIOMassSpectrum class]]) continue;
        TTIOMassSpectrum *ms = (TTIOMassSpectrum *)s;
        if (ms.activationMethod != TTIOActivationMethodNone || ms.isolationWindow != nil) { anyM74 = YES; break; }
    }
    NSMutableData *actM = nil, *isoT = nil, *isoL = nil, *isoU = nil;
    int32_t *actMp = NULL; double *isoTp = NULL, *isoLp = NULL, *isoUp = NULL;
    if (anyM74) {
        actM = [NSMutableData dataWithLength:n * sizeof(int32_t)];
        isoT = [NSMutableData dataWithLength:n * sizeof(double)];
        isoL = [NSMutableData dataWithLength:n * sizeof(double)];
        isoU = [NSMutableData dataWithLength:n * sizeof(double)];
        actMp = actM.mutableBytes; isoTp = isoT.mutableBytes; isoLp = isoL.mutableBytes; isoUp = isoU.mutableBytes;
    }
    NSMutableDictionary<NSString *, NSMutableData *> *data = [NSMutableDictionary dictionary];
    for (NSString *c in channelNames) data[c] = [NSMutableData data];
    NSString *firstChannel = channelNames.firstObject;
    uint64_t cursor = 0;
    for (NSUInteger i = 0; i < n; i++) {
        TTIOSpectrum *s = spectra[i];
        TTIOSignalArray *primary = s.signalArrays[firstChannel];
        off[i] = cursor;
        len[i] = (uint32_t)primary.length;
        rt[i] = s.scanTimeSeconds;
        pmp[i] = s.precursorMz;
        pcp[i] = (int32_t)s.precursorCharge;
        for (NSString *c in channelNames) {
            TTIOSignalArray *a = s.signalArrays[c];
            if (a) [data[c] appendData:[a float64Buffer]];
        }
        if ([s isKindOfClass:[TTIOMassSpectrum class]]) {
            TTIOMassSpectrum *ms = (TTIOMassSpectrum *)s;
            mlp[i] = (int32_t)ms.msLevel;
            plp[i] = (int32_t)ms.polarity;
            double maxI = 0;
            TTIOSignalArray *inA = ms.intensityArray;
            /* -float64Buffer hands back a fresh conversion buffer for
             * any precision other than float64, and nothing else holds
             * it: keep it alive across the scan. */
            NSData *intBuf = [inA float64Buffer];
            const double *intP = intBuf.bytes;
            for (NSUInteger j = 0; j < inA.length; j++) if (intP[j] > maxI) maxI = intP[j];
            bpp[i] = maxI;
            if (anyM74) {
                actMp[i] = (int32_t)ms.activationMethod;
                TTIOIsolationWindow *iw = ms.isolationWindow;
                isoTp[i] = iw ? iw.targetMz : 0.0;
                isoLp[i] = iw ? iw.lowerOffset : 0.0;
                isoUp[i] = iw ? iw.upperOffset : 0.0;
            }
        } else {
            mlp[i] = 0;
            plp[i] = (int32_t)TTIOPolarityUnknown;
            double maxI = 0;
            TTIOSignalArray *inA = s.signalArrays[@"intensity"];
            if (inA) {
                NSData *intBuf = [inA float64Buffer];
                const double *intP = intBuf.bytes;
                for (NSUInteger j = 0; j < inA.length; j++) if (intP[j] > maxI) maxI = intP[j];
            }
            bpp[i] = maxI;
            if (anyM74) { actMp[i] = (int32_t)TTIOActivationMethodNone; isoTp[i] = isoLp[i] = isoUp[i] = 0.0; }
        }
        cursor += primary.length;
    }
    return [[self alloc] initWithOffsets:offsets lengths:lengths retentionTimes:rts msLevels:ml
                              polarities:pol precursorMzs:pmz precursorCharges:pc basePeakIntensities:bp
                       activationMethods:actM isolationTargetMzs:isoT isolationLowerOffsets:isoL
                   isolationUpperOffsets:isoU centroideds:nil channelData:data];
}

@end
