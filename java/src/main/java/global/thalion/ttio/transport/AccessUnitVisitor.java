/*
 * TTI-O Java Implementation.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.IRImage;
import global.thalion.ttio.Identification;
import global.thalion.ttio.MSImage;
import global.thalion.ttio.ProvenanceRecord;
import global.thalion.ttio.Quantification;
import global.thalion.ttio.RamanImage;
import global.thalion.ttio.Sample;
import global.thalion.ttio.Subject;
import global.thalion.ttio.genomics.ReferenceImport;

import java.util.List;

/**
 * Visitor protocol invoked by {@link DatasetWalker} for every
 * transport-stream event a filtered dataset produces. All methods
 * have empty default implementations — concrete visitors override
 * only the events they care about.
 *
 * <p>Event order:
 * <ol>
 *   <li>{@link #visitStreamHeader} once.</li>
 *   <li>v0.11 §5.4 prelude events (when populated):
 *       {@link #visitEncryptionAlgorithm},
 *       {@link #visitDatasetProvenance},
 *       {@link #visitSubjectMetadata},
 *       {@link #visitSampleMetadata},
 *       {@link #visitReferenceGroup} (one per reference, sorted by URI key),
 *       {@link #visitImage},
 *       {@link #visitRamanImage},
 *       {@link #visitIRImage},
 *       {@link #visitIdentificationsTable},
 *       {@link #visitQuantificationsTable}.</li>
 *   <li>{@link #visitDatasetHeader} per matched dataset.</li>
 *   <li>{@link #visitAccessUnit} per matched AU.</li>
 *   <li>{@link #visitEndOfDataset} per matched dataset.</li>
 *   <li>{@link #visitEndOfStream} once.</li>
 * </ol>
 *
 * <p>Cross-language equivalents:
 * <ul>
 *   <li>Objective-C: {@code TTIOTransportEventVisitor}</li>
 *   <li>Python:       {@code ttio.transport.walker.WalkerEvent}
 *                     (variant types yielded by {@code walk_dataset})</li>
 * </ul>
 */
public interface AccessUnitVisitor {

    default void visitStreamHeader(DatasetWalker walker,
                                    String formatVersion,
                                    String title,
                                    String isaInvestigation,
                                    List<String> features,
                                    int nDatasets) {}

    default void visitDatasetHeader(DatasetWalker walker,
                                     int datasetId,
                                     String name,
                                     int acquisitionMode,
                                     String spectrumClass,
                                     List<String> channelNames,
                                     String instrumentJson,
                                     int expectedAUCount) {}

    default void visitAccessUnit(DatasetWalker walker,
                                  AccessUnit au,
                                  int datasetId,
                                  int auSequence) {}

    default void visitEndOfDataset(DatasetWalker walker,
                                    int datasetId,
                                    int finalAUSequence) {}

    default void visitEndOfStream(DatasetWalker walker) {}

    // ── v0.11 §5.4 prelude callbacks (#141) ─────────────────────────

    /** §5.4.1 — dataset-level {@code @encrypted} algorithm name. */
    default void visitEncryptionAlgorithm(DatasetWalker walker,
                                            String algorithm) {}

    /** §5.4.2 — dataset-level provenance chain. */
    default void visitDatasetProvenance(DatasetWalker walker,
                                          List<ProvenanceRecord> records) {}

    /** §5.4.3 — {@link Subject} rows (subjects emit BEFORE samples
     *  so a soft-FK target is visible ahead of any sample row that
     *  references it). */
    default void visitSubjectMetadata(DatasetWalker walker,
                                        List<Subject> rows) {}

    /** §5.4.3 — {@link Sample} rows. */
    default void visitSampleMetadata(DatasetWalker walker,
                                       List<Sample> rows) {}

    /** §5.4.4 — one embedded {@link ReferenceImport} per call. */
    default void visitReferenceGroup(DatasetWalker walker,
                                       ReferenceImport reference) {}

    /** §5.4.5 — embedded {@link MSImage} cube. */
    default void visitImage(DatasetWalker walker,
                              MSImage image) {}

    /** §5.4.5 — embedded {@link RamanImage} cube. */
    default void visitRamanImage(DatasetWalker walker,
                                   RamanImage image) {}

    /** §5.4.5 — embedded {@link IRImage} cube. */
    default void visitIRImage(DatasetWalker walker,
                                IRImage image) {}

    /** §5.4.6 — {@link Identification} rows. */
    default void visitIdentificationsTable(DatasetWalker walker,
                                             List<Identification> rows) {}

    /** §5.4.6 — {@link Quantification} rows. */
    default void visitQuantificationsTable(DatasetWalker walker,
                                             List<Quantification> rows) {}
}
