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
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Export/TTIONmrMLWriter.h</p>
 *
 * <p>nmrML writer. Serialises one NMR spectrum (and optionally its
 * FID) to an nmrML XML document. Mirrors the elements parsed by
 * <code>TTIONmrMLReader</code> so the output round-trips through the
 * reader unchanged.</p>
 *
 * <p><strong>nmrCV accessions emitted:</strong></p>
 * <ul>
 *  <li>NMR:1000001 &#8212; spectrometer frequency (MHz)</li>
 *  <li>NMR:1000002 &#8212; nucleus type</li>
 *  <li>NMR:1000003 &#8212; number of scans</li>
 *  <li>NMR:1000004 &#8212; dwell time (seconds)</li>
 *  <li>NMR:1400014 &#8212; sweep width (ppm)</li>
 * </ul>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.exporters.nmrml</code><br/>
 * Java: <code>global.thalion.ttio.exporters.NmrMLWriter</code></p>
 */
@interface TTIONmrMLWriter : NSObject

/**
 * Serialises a single NMR spectrum (plus optional FID) to an
 * in-memory nmrML XML blob. The spectrum's
 * <code>chemicalShiftArray</code> becomes the
 * <code>&lt;xAxis&gt;</code> and <code>intensityArray</code> the
 * <code>&lt;yAxis&gt;</code>. <code>fid</code> may be
 * <code>nil</code>; if present it is written as
 * <code>&lt;fidData&gt;</code> in base64 complex128.
 *
 * @param spectrum      Spectrum to serialise.
 * @param fid           Optional FID to embed; <code>nil</code> omits.
 * @param sweepWidthPPM Sweep width for the
 *                      <code>&lt;sweepWidth&gt;</code> cvParam; pass
 *                      <code>0</code> to omit.
 * @param error         Out-parameter populated on failure.
 * @return UTF-8 nmrML data, or <code>nil</code> on failure.
 */
+ (NSData *)dataForSpectrum:(TTIONMRSpectrum *)spectrum
                        fid:(TTIOFreeInductionDecay *)fid
              sweepWidthPPM:(double)sweepWidthPPM
                      error:(NSError **)error;

/**
 * Convenience wrapper around <code>+dataForSpectrum:...</code> that
 * writes the result to disk.
 *
 * @param spectrum      Spectrum to serialise.
 * @param fid           Optional FID to embed.
 * @param sweepWidthPPM Sweep width.
 * @param path          Destination path.
 * @param error         Out-parameter populated on failure.
 * @return <code>YES</code> on success, <code>NO</code> on failure.
 */
+ (BOOL)writeSpectrum:(TTIONMRSpectrum *)spectrum
                  fid:(TTIOFreeInductionDecay *)fid
        sweepWidthPPM:(double)sweepWidthPPM
               toPath:(NSString *)path
                error:(NSError **)error;

@end

#endif
