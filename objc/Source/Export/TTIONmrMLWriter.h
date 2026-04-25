/*
 * Licensed under the Apache License, Version 2.0.
 * See LICENSE-IMPORT-EXPORT in the repository root.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef TTIO_NMRML_WRITER_H
#define TTIO_NMRML_WRITER_H

#import <Foundation/Foundation.h>

@class TTIONMRSpectrum;
@class TTIOFreeInductionDecay;

/**
 * Milestone 29 — nmrML writer.
 *
 * Serializes one NMR spectrum (and optionally its FID) to an nmrML XML
 * document. Mirrors the elements parsed by TTIONmrMLReader so the
 * output round-trips through the reader unchanged.
 *
 * nmrCV accessions emitted:
 *   NMR:1000001 — spectrometer frequency (MHz)
 *   NMR:1000002 — nucleus type
 *   NMR:1000003 — number of scans
 *   NMR:1000004 — dwell time (seconds)
 *   NMR:1400014 — sweep width (ppm)
 *
 * API status: Stable.
 *
 * Cross-language equivalents:
 *   Python: ttio.exporters.nmrml
 *   Java:   com.dtwthalion.ttio.exporters.NmrMLWriter
 */
@interface TTIONmrMLWriter : NSObject

/** Serialize a single NMR spectrum (+ optional FID) to an in-memory
 *  nmrML XML blob. The spectrum's ``chemicalShiftArray`` becomes the
 *  ``&lt;xAxis&gt;`` and ``intensityArray`` the ``&lt;yAxis&gt;``.
 *
 *  ``fid`` may be nil; if present it is written as ``&lt;fidData&gt;`` in
 *  base64 complex128. ``sweepWidthPPM`` is required for the
 *  ``&lt;sweepWidth&gt;`` cvParam; pass 0 to omit.
 */
+ (NSData *)dataForSpectrum:(TTIONMRSpectrum *)spectrum
                        fid:(TTIOFreeInductionDecay *)fid
              sweepWidthPPM:(double)sweepWidthPPM
                      error:(NSError **)error;

+ (BOOL)writeSpectrum:(TTIONMRSpectrum *)spectrum
                  fid:(TTIOFreeInductionDecay *)fid
        sweepWidthPPM:(double)sweepWidthPPM
               toPath:(NSString *)path
                error:(NSError **)error;

@end

#endif
