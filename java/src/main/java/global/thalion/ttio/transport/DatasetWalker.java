/*
 * TTI-O Java Implementation.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.transport;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.SpectralDataset;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * Walks a {@link SpectralDataset}, applying an optional
 * {@link AUFilter} and dispatching transport-stream events to an
 * {@link AccessUnitVisitor}. Stateless once constructed; safe to
 * reuse across walks.
 *
 * <p>Iteration order matches
 * {@link TransportWriter#writeDataset(SpectralDataset)} so the
 * sequence of visitor calls is byte-equivalent to canonical dataset
 * emission when the visitor is one that encodes events as packets.
 *
 * <p>Cross-language equivalents:
 * <ul>
 *   <li>Objective-C: {@code TTIODatasetWalker}</li>
 *   <li>Python:       {@code ttio.transport.walker.walk_dataset}</li>
 * </ul>
 */
public final class DatasetWalker {

    /** Walks {@code dataset} event-by-event. Returns silently when
     *  the dataset or visitor is null. */
    public void walk(SpectralDataset dataset,
                      AUFilter filter,
                      AccessUnitVisitor visitor) {
        if (dataset == null || visitor == null) return;
        AUFilter flt = (filter == null) ? new AUFilter() : filter;

        Map<String, AcquisitionRun> runs = dataset.msRuns();
        List<String> features = new ArrayList<>();
        for (String f : dataset.featureFlags().features()) features.add(f);

        // 1. StreamHeader
        visitor.visitStreamHeader(this, "1.2",
                                    dataset.title() == null
                                        ? "" : dataset.title(),
                                    dataset.isaInvestigationId() == null
                                        ? "" : dataset.isaInvestigationId(),
                                    features,
                                    runs.size());

        // 2. DatasetHeaders
        int did = 1;
        for (Map.Entry<String, AcquisitionRun> e : runs.entrySet()) {
            if (flt.datasetId != null && did != flt.datasetId) {
                did++;
                continue;
            }
            AcquisitionRun run = e.getValue();
            List<String> channelNames =
                new ArrayList<>(run.channels().keySet());
            String instrumentJson =
                TransportWriter.instrumentConfigJson(run.instrumentConfig());
            visitor.visitDatasetHeader(this, did, e.getKey(),
                                         run.acquisitionMode().ordinal(),
                                         run.spectrumClassName(),
                                         channelNames,
                                         instrumentJson,
                                         run.spectrumCount());
            did++;
        }

        // 3. AccessUnits
        int emitted = 0;
        Integer maxAu = flt.maxAu;
        did = 1;
        outer:
        for (Map.Entry<String, AcquisitionRun> e : runs.entrySet()) {
            if (flt.datasetId != null && did != flt.datasetId) {
                did++;
                continue;
            }
            AcquisitionRun run = e.getValue();
            int count = run.spectrumCount();
            List<String> channelNames =
                new ArrayList<>(run.channels().keySet());
            for (int i = 0; i < count; i++) {
                if (maxAu != null && emitted >= maxAu) break outer;
                AccessUnit au = TransportWriter.spectrumToAccessUnit(
                    run, i, channelNames);
                if (!flt.matches(au, did)) continue;
                visitor.visitAccessUnit(this, au, did, i);
                emitted++;
            }
            did++;
        }

        // 4. EndOfDataset per dataset
        did = 1;
        for (Map.Entry<String, AcquisitionRun> e : runs.entrySet()) {
            if (flt.datasetId != null && did != flt.datasetId) {
                did++;
                continue;
            }
            AcquisitionRun run = e.getValue();
            visitor.visitEndOfDataset(this, did, run.spectrumCount());
            did++;
        }

        // 5. EndOfStream
        visitor.visitEndOfStream(this);
    }
}
