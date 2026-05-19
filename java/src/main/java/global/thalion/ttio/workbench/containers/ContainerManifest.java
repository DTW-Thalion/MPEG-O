/*
 * TTI-O Java Implementation
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.workbench.containers;

import java.util.List;
import java.util.Map;

/**
 * Container manifest returned by
 * {@code GET /v1/containers/{uri}/manifest}. Summary of what's
 * inside the container without downloading the .tio file.
 *
 * <p>Cross-language equivalent: Python
 * {@code ttio.workbench.containers.ContainerManifest}.</p>
 */
public record ContainerManifest(
        String uri,
        String title,
        String isaInvestigationId,
        List<MsRunSummary> msRuns,
        List<NmrRunSummary> nmrRuns,
        List<GenomicRunSummary> genomicRuns,
        long identificationCount,
        long quantificationCount,
        long provenanceRecordCount) {

    public ContainerManifest {
        msRuns      = msRuns      == null ? List.of() : List.copyOf(msRuns);
        nmrRuns     = nmrRuns     == null ? List.of() : List.copyOf(nmrRuns);
        genomicRuns = genomicRuns == null ? List.of() : List.copyOf(genomicRuns);
    }

    public record MsRunSummary(
            String name,
            String spectrumClass,
            int acquisitionMode,
            List<String> channelNames,
            long spectrumCount,
            Map<String, Long> msLevelDistribution) {

        public MsRunSummary {
            channelNames        = channelNames        == null
                ? List.of() : List.copyOf(channelNames);
            msLevelDistribution = msLevelDistribution == null
                ? Map.of()  : Map.copyOf(msLevelDistribution);
        }

        @SuppressWarnings("unchecked")
        static MsRunSummary fromJson(Map<String, Object> body) {
            Map<String, Long> dist = new java.util.LinkedHashMap<>();
            Object rawDist = body.get("ms_level_distribution");
            if (rawDist instanceof Map<?, ?> m) {
                for (var e : m.entrySet()) {
                    String k = String.valueOf(e.getKey());
                    long v = e.getValue() instanceof Number n
                        ? n.longValue() : 0L;
                    dist.put(k, v);
                }
            }
            return new MsRunSummary(
                (String) body.get("name"),
                (String) body.get("spectrum_class"),
                body.get("acquisition_mode") instanceof Number an
                    ? an.intValue() : 0,
                (List<String>) body.getOrDefault("channel_names", List.of()),
                Container.longField(body.get("spectrum_count")),
                dist);
        }
    }

    public record NmrRunSummary(String name, long spectrumCount) {
        static NmrRunSummary fromJson(Map<String, Object> body) {
            return new NmrRunSummary(
                (String) body.get("name"),
                Container.longField(body.get("spectrum_count")));
        }
    }

    public record GenomicRunSummary(String name, long readCount, String platform) {
        static GenomicRunSummary fromJson(Map<String, Object> body) {
            return new GenomicRunSummary(
                (String) body.get("name"),
                Container.longField(body.get("read_count")),
                (String) body.get("platform"));
        }
    }

    @SuppressWarnings("unchecked")
    public static ContainerManifest fromJson(Map<String, Object> body) {
        List<Map<String, Object>> ms = (List<Map<String, Object>>)
            body.getOrDefault("ms_runs", List.of());
        List<Map<String, Object>> nmr = (List<Map<String, Object>>)
            body.getOrDefault("nmr_runs", List.of());
        List<Map<String, Object>> gen = (List<Map<String, Object>>)
            body.getOrDefault("genomic_runs", List.of());
        return new ContainerManifest(
            (String) body.get("uri"),
            (String) body.get("title"),
            (String) body.get("isa_investigation_id"),
            ms.stream().map(MsRunSummary::fromJson).toList(),
            nmr.stream().map(NmrRunSummary::fromJson).toList(),
            gen.stream().map(GenomicRunSummary::fromJson).toList(),
            Container.longField(body.get("identification_count")),
            Container.longField(body.get("quantification_count")),
            Container.longField(body.get("provenance_record_count")));
    }
}
