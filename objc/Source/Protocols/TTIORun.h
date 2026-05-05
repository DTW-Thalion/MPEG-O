#ifndef TTIO_RUN_H
#define TTIO_RUN_H

#import <Foundation/Foundation.h>
#import "Protocols/TTIOIndexable.h"
#import "ValueClasses/TTIOEnums.h"

@class TTIOProvenanceRecord;

/**
 * <p><em>Conforms To:</em> TTIOIndexable, NSObject</p>
 * <p><em>Declared In:</em> Protocols/TTIORun.h</p>
 *
 * <p>Modality-agnostic interface for an acquisition or sequencing
 * run inside a <code>TTIOSpectralDataset</code>. A run is a sequence
 * of measurements (mass / NMR spectra in the spectroscopy case,
 * aligned reads in the genomic case) that share an acquisition mode,
 * an instrument context, and a provenance chain.</p>
 *
 * <p>Both <code>TTIOAcquisitionRun</code> and
 * <code>TTIOGenomicRun</code> conform to this protocol so callers
 * can iterate uniformly without knowing the underlying modality.
 * Modality-specific work (e.g. extracting a CIGAR string from an
 * aligned read, or a precursor m/z from a mass spectrum) requires
 * narrowing via <code>-isKindOfClass:</code> to the concrete class.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.protocols.run.Run</code><br/>
 * Java: <code>global.thalion.ttio.protocols.Run</code></p>
 */
@protocol TTIORun <TTIOIndexable>

@required

/**
 * Run identifier as stored in the .tio file (e.g.
 * <code>@"run_0001"</code> or <code>@"genomic_0001"</code>).
 */
@property (readonly, copy) NSString *name;

/**
 * Acquisition-mode enum value identifying the instrument or protocol
 * context. See <code>TTIOAcquisitionMode</code> for the enumerated
 * values.
 */
@property (readonly) TTIOAcquisitionMode acquisitionMode;

/**
 * @return Per-run provenance records in insertion order. Empty array
 *         if the run has no provenance attached.
 */
- (NSArray<TTIOProvenanceRecord *> *)provenanceChain;

@end

#endif /* TTIO_RUN_H */
