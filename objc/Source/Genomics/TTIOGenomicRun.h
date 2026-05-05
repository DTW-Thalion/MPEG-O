#ifndef TTIO_GENOMIC_RUN_H
#define TTIO_GENOMIC_RUN_H

#import <Foundation/Foundation.h>
#import "Protocols/TTIOIndexable.h"
#import "Protocols/TTIORun.h"
#import "ValueClasses/TTIOEnums.h"

@class TTIOAlignedRead;
@class TTIOGenomicIndex;
@class TTIOProvenanceRecord;
@protocol TTIOStorageGroup;

/**
 * <heading>TTIOGenomicRun</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> TTIOIndexable, TTIORun</p>
 * <p><em>Declared In:</em> Genomics/TTIOGenomicRun.h</p>
 *
 * <p>Lazy view over one
 * <code>/study/genomic_runs/&lt;name&gt;/</code> group.
 * Materialises <code>TTIOAlignedRead</code> objects on demand from
 * the signal channels. The <code>TTIOGenomicIndex</code> is loaded
 * eagerly at open time for cheap filtering and offset lookups; the
 * heavy signal channels (sequences, qualities, plus the inline
 * codec channels) stay lazy on disk.</p>
 *
 * <p>Genomic analogue of <code>TTIOAcquisitionRun</code>; both
 * conform to <code>TTIORun</code> so cross-modality code can
 * iterate uniformly via <code>-objectAtIndex:</code> /
 * <code>-count</code>.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.genomic_run.GenomicRun</code><br/>
 * Java: <code>global.thalion.ttio.genomics.GenomicRun</code></p>
 */
@interface TTIOGenomicRun : NSObject <TTIOIndexable, TTIORun>

/** Run identifier as stored in the .tio file (e.g.
 *  <code>@"genomic_0001"</code>). */
@property (readonly, copy) NSString *name;

/** Acquisition mode (typically
 *  <code>TTIOAcquisitionModeGenomicWGS</code> or
 *  <code>WES</code>). */
@property (readonly) TTIOAcquisitionMode acquisitionMode;

/** Omics modality identifier (typically
 *  <code>@"genomic_sequencing"</code>). */
@property (readonly, copy) NSString *modality;

/** URI of the reference genome (e.g. <code>@"GRCh38.p14"</code>). */
@property (readonly, copy) NSString *referenceUri;

/** Sequencing platform (e.g. <code>@"ILLUMINA"</code>). */
@property (readonly, copy) NSString *platform;

/** Sample identifier. */
@property (readonly, copy) NSString *sampleName;

/** Per-read index loaded eagerly at open. */
@property (readonly, strong) TTIOGenomicIndex *index;

/** @return Number of reads in the run. */
- (NSUInteger)readCount;

/** @return <code>readCount</code> (TTIOIndexable conformance). */
- (NSUInteger)count;

/**
 * @param index Zero-based read position.
 * @return The <code>TTIOAlignedRead</code> at <code>index</code>,
 *         or <code>nil</code> on error / out-of-range.
 */
- (id)objectAtIndex:(NSUInteger)index;

/**
 * @return Per-run provenance records in insertion order, read from
 *         <code>&lt;run&gt;/provenance/steps</code>. Empty array
 *         when the run carries no provenance.
 */
- (NSArray<TTIOProvenanceRecord *> *)provenanceChain;

/**
 * Materialises the read at <code>index</code>.
 *
 * @param index Zero-based read position.
 * @param error Out-parameter populated on failure.
 * @return The aligned read, or <code>nil</code> on failure.
 */
- (TTIOAlignedRead *)readAtIndex:(NSUInteger)index
                           error:(NSError **)error;

/**
 * Returns the read name at <code>index</code>. Decodes from the
 * NAME_TOKENIZED_V2 stream stored under the
 * <code>signal_channels/read_names</code> dataset; the decoded
 * list is materialised on first call and cached for the lifetime
 * of this run instance.
 *
 * @param index Zero-based read position.
 * @param error Out-parameter populated on failure.
 * @return The read name, or <code>nil</code> on failure.
 */
- (NSString *)readNameAtIndex:(NSUInteger)index
                        error:(NSError **)error;

/**
 * Returns the CIGAR string at <code>index</code>. Decodes the
 * cigars channel (rANS-O0 or rANS-O1, length-prefix-concat
 * varint+bytes); the decoded list is materialised on first call
 * and cached for the lifetime of this run instance.
 *
 * @param index Zero-based read position.
 * @param error Out-parameter populated on failure.
 * @return The CIGAR string, or <code>nil</code> on failure.
 */
- (NSString *)cigarAtIndex:(NSUInteger)index
                     error:(NSError **)error;

/**
 * @param chromosome Reference chromosome.
 * @param start      Inclusive lower bound on position.
 * @param end        Exclusive upper bound on position.
 * @return Reads on <code>chromosome</code> whose mapping position
 *         is in <code>[start, end)</code>.
 */
- (NSArray<TTIOAlignedRead *> *)readsInRegion:(NSString *)chromosome
                                        start:(int64_t)start
                                          end:(int64_t)end;

/**
 * Opens an existing
 * <code>/study/genomic_runs/&lt;name&gt;/</code> group. The caller
 * resolves the run group and passes it as <code>runGroup</code>.
 *
 * @param runGroup The run sub-group.
 * @param name     Run name.
 * @param error    Out-parameter populated on failure.
 * @return The opened run, or <code>nil</code> on failure.
 */
+ (instancetype)openFromGroup:(id<TTIOStorageGroup>)runGroup
                         name:(NSString *)name
                        error:(NSError **)error;

/**
 * Returns the codec id (<code>TTIOCompression</code> value) declared
 * on the named signal channel via its <code>@compression</code>
 * attribute, or <code>0</code> (NONE) when the attribute is absent.
 * The transport writer probes this for sequences / qualities to
 * decide whether each per-AU slice should be re-encoded with that
 * codec on the wire.
 *
 * @param name Signal-channel dataset name.
 * @return Codec id, or <code>0</code> when no codec is declared.
 */
- (uint8_t)wireCompressionForChannel:(NSString *)name;

@end

#endif
