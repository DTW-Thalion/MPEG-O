/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_DATASET_WALKER_H
#define TTIO_DATASET_WALKER_H

#import <Foundation/Foundation.h>
#import "TTIOAccessUnit.h"

@class TTIOSpectralDataset;
@class TTIOAUFilter;
@class TTIODatasetWalker;
@class TTIOReferenceImport;
@class TTIOProvenanceRecord;
@class TTIOSubject;
@class TTIOSample;
@class TTIOMSImage;
@class TTIORamanImage;
@class TTIOIRImage;
@class TTIOIdentification;
@class TTIOQuantification;

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Inherits From:</em> NSObject (informal)</p>
 * <p><em>Declared In:</em> Transport/TTIODatasetWalker.h</p>
 *
 * <p>Visitor protocol invoked by <code>TTIODatasetWalker</code> for
 * every transport-stream event a filtered dataset produces. All
 * methods are optional — visitors implement only the events they
 * care about.</p>
 *
 * <p>Event order:</p>
 *
 * <ol>
 *  <li><code>-walker:visitStreamHeader…</code> once.</li>
 *  <li><code>-walker:visitDatasetHeader…</code> per matched dataset
 *      (in iteration order: MS runs sorted by name, then genomic
 *      runs sorted by name).</li>
 *  <li><code>-walker:visitAccessUnit…</code> per matched AU.</li>
 *  <li><code>-walker:visitEndOfDataset…</code> per matched dataset.</li>
 *  <li><code>-walker:visitEndOfStream</code> once.</li>
 * </ol>
 *
 * <p>Implementations of two well-known visitors live in libTTIO:</p>
 * <ul>
 *  <li><strong>Encoding visitor</strong>: wraps a
 *      <code>TTIOTransportWriter</code> to emit each event as the
 *      corresponding transport packet. Used by
 *      <code>TTIOTransportServer</code> for filtered WS downloads
 *      and by the workbench server's S3 binary-mode session.</li>
 *  <li><strong>Stats visitor</strong>: ignores everything except
 *      <code>-walker:visitAccessUnit…</code> and emits
 *      <code>TTIOAUStats</code> JSON per AU. Used by the workbench
 *      server's <code>stats-only</code> and
 *      <code>stats-with-payload</code> modes.</li>
 * </ul>
 */
@protocol TTIOTransportEventVisitor <NSObject>
@optional
/**
 * Receive the stream-level header event.
 *
 * Emitted exactly once at the start of the walk. Carries the
 * fields the writer would have packed into ``STREAM_HEADER`` (0x01).
 *
 * @param walker            Walker emitting the event.
 * @param formatVersion     Container format version string.
 * @param title             Container title (may be empty).
 * @param isaInvestigation  ISA-Tab investigation identifier.
 * @param features          Feature flag strings declared on the
 *                          stream.
 * @param nDatasets         Number of dataset blocks emitted.
 */
- (void)walker:(TTIODatasetWalker *)walker
visitStreamHeaderWithFormatVersion:(NSString *)formatVersion
                              title:(NSString *)title
                   isaInvestigation:(NSString *)isaInvestigation
                           features:(NSArray<NSString *> *)features
                         nDatasets:(uint16_t)nDatasets;

/**
 * Receive a per-dataset header event.
 *
 * Emitted once per matched dataset before any of its access
 * units. Carries the fields the writer would have packed into
 * ``DATASET_HEADER`` (0x02).
 *
 * @param walker           Walker emitting the event.
 * @param datasetId        1-based dataset id in the stream.
 * @param name             Dataset (run) name.
 * @param acquisitionMode  Wire encoding of the acquisition mode.
 * @param spectrumClass    Spectrum class name.
 * @param channelNames     Ordered signal-channel names.
 * @param instrumentJSON   JSON-encoded instrument config.
 * @param expectedAUCount  Total AU count for the dataset.
 */
- (void)walker:(TTIODatasetWalker *)walker
visitDatasetHeaderWithDatasetId:(uint16_t)datasetId
                            name:(NSString *)name
                 acquisitionMode:(uint8_t)acquisitionMode
                   spectrumClass:(NSString *)spectrumClass
                    channelNames:(NSArray<NSString *> *)channelNames
                  instrumentJSON:(NSString *)instrumentJSON
                expectedAUCount:(uint32_t)expectedAUCount;

/**
 * Receive one access-unit event.
 *
 * Emitted once per AU that survives the active ``TTIOAUFilter``.
 *
 * @param walker      Walker emitting the event.
 * @param au          The access unit. Borrowed.
 * @param datasetId   Owning dataset id.
 * @param auSequence  0-based AU index within the dataset.
 */
- (void)walker:(TTIODatasetWalker *)walker
 visitAccessUnit:(TTIOAccessUnit *)au
       datasetId:(uint16_t)datasetId
      auSequence:(uint32_t)auSequence;

/**
 * Receive a per-dataset end-of-dataset event.
 *
 * Emitted once per matched dataset after its access units.
 *
 * @param walker           Walker emitting the event.
 * @param datasetId        Owning dataset id.
 * @param finalAUSequence  One past the last AU sequence emitted.
 */
- (void)walker:(TTIODatasetWalker *)walker
visitEndOfDatasetWithDatasetId:(uint16_t)datasetId
                finalAUSequence:(uint32_t)finalAUSequence;

/**
 * Receive the end-of-stream event.
 *
 * Emitted exactly once after all per-dataset events. No further
 * visitor methods fire for this walk.
 *
 * @param walker Walker emitting the event.
 */
- (void)walkerVisitEndOfStream:(TTIODatasetWalker *)walker;

/* ────────────────────────────────────────────────────────────────
 * v0.11 prelude visitor methods. Emitted (when the corresponding
 * accessor is non-empty / non-nil on the dataset) between the
 * StreamHeader and the first DatasetHeader, in transport-spec §5.4
 * order:
 *   §5.4.1 encryption_algorithm
 *   §5.4.2 dataset_provenance
 *   §5.4.3 subjects  → samples
 *   §5.4.4 reference groups (one call per import)
 *   §5.4.5 images   (MS → Raman → IR)
 *   §5.4.6 identifications → quantifications
 * Mirrors the emission order in TTIOTransportWriter writeDataset:.
 * Filed as #140 — walker previously emitted only MS AUs and dropped
 * every v0.11 accessor on the workbench daemon's download path.
 * ──────────────────────────────────────────────────────────────── */

/**
 * Receive the dataset-level @encrypted algorithm name (transport-spec §4.23).
 *
 * Fires only when the source dataset has an ``@encrypted`` root
 * attribute. Counterpart to ``ENCRYPTION_ALGORITHM`` (0x1B).
 *
 * @param walker     Walker emitting the event.
 * @param algorithm  Encryption algorithm identifier (e.g.
 *                   ``@"aes-256-gcm"``).
 */
- (void)walker:(TTIODatasetWalker *)walker
visitEncryptionAlgorithm:(NSString *)algorithm;

/**
 * Receive the dataset-level provenance chain (transport-spec §4.21).
 *
 * Counterpart to ``DATASET_PROVENANCE`` (0x18). Skipped when the
 * dataset has no provenance records.
 *
 * @param walker   Walker emitting the event.
 * @param records  Ordered list of provenance records.
 */
- (void)walker:(TTIODatasetWalker *)walker
visitDatasetProvenance:(NSArray<TTIOProvenanceRecord *> *)records;

/**
 * Receive the dataset's subject metadata table (transport-spec §4.22).
 *
 * Counterpart to ``SUBJECT_METADATA`` (0x19). Skipped on
 * empty-table sources.
 *
 * @param walker  Walker emitting the event.
 * @param rows    Subject rows in declaration order.
 */
- (void)walker:(TTIODatasetWalker *)walker
visitSubjectMetadata:(NSArray<TTIOSubject *> *)rows;

/**
 * Receive the dataset's sample metadata table (transport-spec §4.22).
 *
 * Counterpart to ``SAMPLE_METADATA`` (0x1A). Skipped on
 * empty-table sources.
 *
 * @param walker  Walker emitting the event.
 * @param rows    Sample rows in declaration order.
 */
- (void)walker:(TTIODatasetWalker *)walker
visitSampleMetadata:(NSArray<TTIOSample *> *)rows;

/**
 * Receive one reference-genome import (transport-spec §4.13-§4.15).
 *
 * Emitted once per ``TTIOReferenceImport`` on the dataset. The
 * encoding visitor expands each call into the
 * ``REFERENCE_GROUP_HEADER`` / ``REFERENCE_CHROMOSOME`` /
 * ``END_OF_REFERENCE_GROUP`` packet sequence.
 *
 * @param walker     Walker emitting the event.
 * @param reference  Imported reference (URI + per-chromosome sequences).
 */
- (void)walker:(TTIODatasetWalker *)walker
visitReferenceGroup:(TTIOReferenceImport *)reference;

/**
 * Receive the dataset's MS image cube (transport-spec §4.16-§4.18).
 *
 * Fires when the dataset has a populated ``image`` property.
 *
 * @param walker  Walker emitting the event.
 * @param image   Mass-spectrometry image cube.
 */
- (void)walker:(TTIODatasetWalker *)walker
visitImage:(TTIOMSImage *)image;

/**
 * Receive the dataset's Raman image cube (transport-spec §4.16).
 *
 * Fires when the dataset has a populated ``ramanImage`` property.
 *
 * @param walker  Walker emitting the event.
 * @param image   Raman image cube.
 */
- (void)walker:(TTIODatasetWalker *)walker
visitRamanImage:(TTIORamanImage *)image;

/**
 * Receive the dataset's IR image cube (transport-spec §4.16).
 *
 * Fires when the dataset has a populated ``irImage`` property.
 *
 * @param walker  Walker emitting the event.
 * @param image   IR image cube.
 */
- (void)walker:(TTIODatasetWalker *)walker
visitIRImage:(TTIOIRImage *)image;

/**
 * Receive the dataset's identifications table (transport-spec §4.19).
 *
 * Counterpart to ``IDENTIFICATIONS_TABLE`` (0x16). Skipped on
 * empty-table sources.
 *
 * @param walker  Walker emitting the event.
 * @param rows    Identification rows in declaration order.
 */
- (void)walker:(TTIODatasetWalker *)walker
visitIdentificationsTable:(NSArray<TTIOIdentification *> *)rows;

/**
 * Receive the dataset's quantifications table (transport-spec §4.20).
 *
 * Counterpart to ``QUANTIFICATIONS_TABLE`` (0x17). Skipped on
 * empty-table sources.
 *
 * @param walker  Walker emitting the event.
 * @param rows    Quantification rows in declaration order.
 */
- (void)walker:(TTIODatasetWalker *)walker
visitQuantificationsTable:(NSArray<TTIOQuantification *> *)rows;
@end


/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Transport/TTIODatasetWalker.h</p>
 *
 * <p>Walks a <code>TTIOSpectralDataset</code> packet-event by
 * packet-event, applying an optional <code>TTIOAUFilter</code> and
 * dispatching to a visitor. Stateless once constructed; safe to
 * reuse across walks.</p>
 *
 * <p>Walking order matches the transport-stream emission order
 * baked into <code>TTIOTransportWriter writeDataset:</code> so the
 * sequence of visitor calls is byte-equivalent to the canonical
 * dataset emission when the visitor is the encoding one.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python:
 *   <code>ttio.transport.walker.walk_dataset</code> (generator)<br/>
 * Java:
 *   <code>global.thalion.ttio.transport.DatasetWalker</code></p>
 */
@interface TTIODatasetWalker : NSObject

/**
 * Walk a dataset event-by-event and dispatch to a visitor.
 *
 * Iterates every MS run then every genomic run (each sorted by
 * name), applying ``filter`` to each constructed AU before
 * dispatching the events documented on
 * ``TTIOTransportEventVisitor``. The walker instance is stateless
 * across walks; reuse freely.
 *
 * @param dataset  Source dataset. Borrowed.
 * @param filter   Optional AU filter (ms_level / RT / precursor
 *                 m/z / polarity / dataset_id / max_au). ``nil``
 *                 admits every AU.
 * @param visitor  Visitor receiving the events.
 * @param error    On failure, populated with an ``NSError``. May
 *                 be ``NULL``.
 *
 * @return ``YES`` on success, ``NO`` on failure.
 */
- (BOOL)walkDataset:(TTIOSpectralDataset *)dataset
              filter:(nullable TTIOAUFilter *)filter
             visitor:(id<TTIOTransportEventVisitor>)visitor
               error:(NSError * _Nullable *)error;

@end

NS_ASSUME_NONNULL_END

#endif
