/*
 * TTI-O Objective-C Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <Foundation/Foundation.h>

@class TTIOSpectralDataset;
@class TTIOAcquisitionRun;
@class TTIOGenomicRun;
@class TTIOWrittenGenomicRun;

NS_ASSUME_NONNULL_BEGIN

/**
 * Run-selection helpers shared by the export registry and the per-format
 * <code>TTIOWriter</code> adapters. Each picks the right
 * <code>TTIOAcquisitionRun</code> (or genomic run) from an opened
 * <code>TTIOSpectralDataset</code> given an optional <code>layer</code>
 * name.
 *
 * <p>This is the ObjC port of the Python reference
 * <code>ttio.exporters._select</code> (<code>analytical_run</code> /
 * <code>nmr_run</code> / <code>genomic_run</code>) and Java
 * <code>RunSelection</code>. The error-message strings are kept
 * byte-identical to Python so cross-language error parity holds; the
 * messages surface as the returned <code>NSError</code>'s
 * <code>localizedDescription</code> (Python raises <code>KeyError</code>).</p>
 *
 * <p><b>Structural difference from Python:</b> Python merges two run maps
 * (<code>ds.ms_runs</code> and <code>ds.nmr_runs</code>). In ObjC the
 * dataset's <code>nmrRuns</code> is a map of <i>spectrum collections</i>
 * (<code>NSArray&lt;TTIONMRSpectrum&nbsp;*&gt;</code>), not analytical
 * runs; the analytical runs (MS and NMR alike) all live in
 * <code>msRuns</code> as <code>TTIOAcquisitionRun</code> and are
 * distinguished by
 * <code>spectrumClassName isEqualToString:@"TTIONMRSpectrum"</code> — the
 * same discriminant Python applies via <code>spectrum_class</code>, and
 * the same adaptation the Java port made. Selection behaviour is
 * therefore equivalent to Python's intent.</p>
 *
 * @since 1.7.0
 */
@interface TTIORunSelection : NSObject

/**
 * Select an analytical run (any spectrum class — MS or NMR) by
 * <code>layer</code> name, or the single run when unambiguous. Mirrors
 * Python's <code>analytical_run</code>.
 *
 * @param ds    The opened dataset to select from.
 * @param layer Optional run name; <code>nil</code>/empty selects the
 *              sole run when unambiguous.
 * @param error On failure, set to an <code>NSError</code> whose
 *              <code>localizedDescription</code> mirrors Python's
 *              <code>KeyError</code> text.
 * @return The selected run, or <code>nil</code> + <code>error</code> when
 *         there are no analytical runs, the named <code>layer</code> is
 *         absent, or <code>layer</code> is nil and multiple runs are
 *         present (ambiguous).
 */
+ (nullable TTIOAcquisitionRun *)analyticalRunIn:(TTIOSpectralDataset *)ds
                                           layer:(nullable NSString *)layer
                                           error:(NSError **)error;

/**
 * Select an NMR run, preferring the NMR-classed run, falling back to the
 * sole analytical run. Mirrors Python's <code>nmr_run</code>.
 *
 * @param ds    The opened dataset to select from.
 * @param layer Optional run name; <code>nil</code>/empty prefers the
 *              NMR-classed run, else the sole run.
 * @param error On failure, set to an <code>NSError</code> mirroring
 *              Python's <code>KeyError</code> text.
 * @return The selected run, or <code>nil</code> + <code>error</code>.
 */
+ (nullable TTIOAcquisitionRun *)nmrRunIn:(TTIOSpectralDataset *)ds
                                    layer:(nullable NSString *)layer
                                    error:(NSError **)error;

/**
 * Select a genomic run by <code>layer</code> name, or the single run when
 * unambiguous. Mirrors Python's <code>genomic_run</code>.
 *
 * <p>Returns the dataset's read-side <code>TTIOGenomicRun</code>;
 * callers needing a write-side run for BAM/CRAM export pass the result
 * through <code>+writtenFromGenomicRun:</code>.</p>
 *
 * @param ds    The opened dataset to select from.
 * @param layer Optional genomic-run name; <code>nil</code>/empty selects
 *              the sole run.
 * @param error On failure, set to an <code>NSError</code> mirroring
 *              Python's <code>KeyError</code> text.
 * @return The selected genomic run, or <code>nil</code> +
 *         <code>error</code>.
 */
+ (nullable TTIOGenomicRun *)genomicRunIn:(TTIOSpectralDataset *)ds
                                    layer:(nullable NSString *)layer
                                    error:(NSError **)error;

/**
 * Materialise a read-side <code>TTIOGenomicRun</code> (as returned by the
 * opened dataset's <code>genomicRuns</code>) into a write-side
 * <code>TTIOWrittenGenomicRun</code> for BAM / CRAM export, whose
 * <code>-writeRun:</code> requires the written form.
 *
 * <p>ObjC port of the Java <code>RunSelection.toWritten</code> shared
 * conversion: every per-read field is materialised from the run's index
 * and its per-read <code>TTIOAlignedRead</code> objects into the parallel
 * <code>NSData</code> / <code>NSArray</code> channels the writer expects.
 * Sequences and qualities are concatenated and sliced by the
 * offsets/lengths channels. Compression defaults to
 * <code>TTIOCompressionNone</code>.</p>
 *
 * @param readSideRun A read-side <code>TTIOGenomicRun</code>.
 * @return A freshly materialised <code>TTIOWrittenGenomicRun</code>.
 */
+ (TTIOWrittenGenomicRun *)writtenFromGenomicRun:(TTIOGenomicRun *)readSideRun;

@end

NS_ASSUME_NONNULL_END
