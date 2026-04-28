#ifndef TTIO_RUN_H
#define TTIO_RUN_H

#import <Foundation/Foundation.h>
#import "Protocols/TTIOIndexable.h"
#import "ValueClasses/TTIOEnums.h"

@class TTIOProvenanceRecord;

/**
 * Modality-agnostic Protocol for an acquisition or sequencing run
 * inside a TTI-O SpectralDataset.
 *
 * A "run" is a sequence of measurements (spectra in the MS / NMR /
 * FID case, aligned reads in the genomic case) that share an
 * acquisition mode, instrument context, and provenance chain. Both
 * TTIOAcquisitionRun and TTIOGenomicRun conform to this protocol so
 * callers can iterate uniformly without knowing the underlying
 * modality.
 *
 * Modality-specific work (e.g. extracting a CIGAR string from an
 * aligned read, or a precursor m/z from a mass spectrum) requires
 * narrowing via -isKindOfClass: to the concrete class.
 *
 * API status: Provisional (Phase 1 abstraction polish, post-M91).
 *
 * Cross-language equivalents:
 *   Python: ttio.protocols.run.Run
 *   Java:   global.thalion.ttio.protocols.Run
 */
@protocol TTIORun <TTIOIndexable>

@required

/** Run identifier as stored in the .tio file (e.g. ``@"run_0001"``
 *  or ``@"genomic_0001"``). */
@property (readonly, copy) NSString *name;

/** Acquisition mode enum value identifying the instrument /
 *  protocol context. */
@property (readonly) TTIOAcquisitionMode acquisitionMode;

/** Per-run provenance records in insertion order. Empty array
 *  when the run has no provenance attached. */
- (NSArray<TTIOProvenanceRecord *> *)provenanceChain;

@end

#endif /* TTIO_RUN_H */
