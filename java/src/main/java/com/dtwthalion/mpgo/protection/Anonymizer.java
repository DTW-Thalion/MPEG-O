/* MPEG-O Java Implementation / Copyright (C) 2026 DTW-Thalion / SPDX-License-Identifier: LGPL-3.0-or-later */
package com.dtwthalion.mpgo.protection;

import com.dtwthalion.mpgo.*;
import com.dtwthalion.mpgo.Enums.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

public class Anonymizer {

    public record AnonymizationPolicy(
        boolean redactSaavSpectra,
        double maskIntensityBelowQuantile,  // 0.0 = disabled
        boolean maskRareMetabolites,
        double rareMetaboliteThreshold,     // default 0.05
        int coarsenMzDecimals,              // -1 = disabled
        int coarsenChemicalShiftDecimals,   // -1 = disabled
        boolean stripMetadata
    ) {
        public static AnonymizationPolicy defaults() {
            return new AnonymizationPolicy(
                true, 0.0, false, 0.05, -1, -1, true);
        }
    }

    public record AnonymizationResult(
        SpectralDataset dataset,
        int spectraRedacted,
        int intensitiesZeroed,
        int mzValuesCoarsened,
        int chemicalShiftValuesCoarsened,
        int metabolitesMasked,
        int metadataFieldsStripped
    ) {}

    /** Apply anonymization policies to a dataset, writing a new anonymized file. */
    public static AnonymizationResult anonymize(
            SpectralDataset source, String outputPath, AnonymizationPolicy policy) {
        return anonymize(source, outputPath, policy, loadDefaultPrevalence());
    }

    public static AnonymizationResult anonymize(
            SpectralDataset source, String outputPath,
            AnonymizationPolicy policy, Map<String, Double> prevalenceTable) {

        int spectraRedacted = 0;
        int intensitiesZeroed = 0;
        int mzValuesCoarsened = 0;
        int csValuesCoarsened = 0;
        int metabolitesMasked = 0;
        int metadataFieldsStripped = 0;

        // Build set of SAAV spectrum indices to redact
        Set<String> saavRunSpecs = new HashSet<>();
        if (policy.redactSaavSpectra()) {
            for (Identification id : source.identifications()) {
                if (isSaav(id.chemicalEntity())) {
                    saavRunSpecs.add(id.runName() + ":" + id.spectrumIndex());
                }
            }
            spectraRedacted = saavRunSpecs.size();
        }

        // Process runs
        List<AcquisitionRun> anonymizedRuns = new ArrayList<>();
        for (var entry : source.msRuns().entrySet()) {
            String runName = entry.getKey();
            AcquisitionRun run = entry.getValue();
            SpectrumIndex idx = run.spectrumIndex();

            // Copy channels
            Map<String, double[]> newChannels = new LinkedHashMap<>();
            for (var chEntry : run.channels().entrySet()) {
                newChannels.put(chEntry.getKey(), chEntry.getValue().clone());
            }

            // Per-spectrum processing
            for (int i = 0; i < idx.count(); i++) {
                String specKey = runName + ":" + i;
                long offset = idx.offsetAt(i);
                int length = idx.lengthAt(i);

                // SAAV redaction: zero out both channels
                if (policy.redactSaavSpectra() && saavRunSpecs.contains(specKey)) {
                    for (double[] ch : newChannels.values()) {
                        Arrays.fill(ch, (int) offset, (int) offset + length, 0.0);
                    }
                    continue; // skip further processing for redacted spectra
                }

                // Rare metabolite masking
                if (policy.maskRareMetabolites()) {
                    for (Identification id : source.identifications()) {
                        if (id.runName().equals(runName) && id.spectrumIndex() == i) {
                            Double prev = prevalenceTable.get(id.chemicalEntity());
                            if (prev != null && prev < policy.rareMetaboliteThreshold()) {
                                double[] intensity = newChannels.get("intensity");
                                if (intensity != null) {
                                    Arrays.fill(intensity, (int) offset,
                                            (int) offset + length, 0.0);
                                    metabolitesMasked++;
                                }
                            }
                        }
                    }
                }
            }

            // Intensity quantile masking (global across run)
            if (policy.maskIntensityBelowQuantile() > 0) {
                double[] intensity = newChannels.get("intensity");
                if (intensity != null) {
                    double threshold = quantileThreshold(intensity,
                            policy.maskIntensityBelowQuantile());
                    for (int i = 0; i < intensity.length; i++) {
                        if (intensity[i] < threshold && intensity[i] != 0) {
                            intensity[i] = 0.0;
                            intensitiesZeroed++;
                        }
                    }
                }
            }

            // m/z coarsening
            if (policy.coarsenMzDecimals() >= 0) {
                double[] mz = newChannels.get("mz");
                if (mz != null) {
                    double factor = Math.pow(10, policy.coarsenMzDecimals());
                    for (int i = 0; i < mz.length; i++) {
                        double rounded = Math.round(mz[i] * factor) / factor;
                        if (rounded != mz[i]) mzValuesCoarsened++;
                        mz[i] = rounded;
                    }
                }
            }

            // Chemical shift coarsening
            if (policy.coarsenChemicalShiftDecimals() >= 0) {
                double[] cs = newChannels.get("chemical_shift");
                if (cs != null) {
                    double factor = Math.pow(10, policy.coarsenChemicalShiftDecimals());
                    for (int i = 0; i < cs.length; i++) {
                        double rounded = Math.round(cs[i] * factor) / factor;
                        if (rounded != cs[i]) csValuesCoarsened++;
                        cs[i] = rounded;
                    }
                }
            }

            anonymizedRuns.add(new AcquisitionRun(runName, run.acquisitionMode(),
                    idx, run.instrumentConfig(), newChannels,
                    run.chromatograms(), run.provenanceRecords(),
                    run.nucleusType(), run.spectrometerFrequencyMHz()));
        }

        // Metadata stripping
        String title = source.title();
        if (policy.stripMetadata()) {
            title = "";
            metadataFieldsStripped = 1;
        }

        // Build provenance record
        Map<String, String> params = new LinkedHashMap<>();
        params.put("spectra_redacted", String.valueOf(spectraRedacted));
        params.put("intensities_zeroed", String.valueOf(intensitiesZeroed));
        params.put("mz_values_coarsened", String.valueOf(mzValuesCoarsened));
        params.put("chemical_shift_values_coarsened", String.valueOf(csValuesCoarsened));
        params.put("metabolites_masked", String.valueOf(metabolitesMasked));
        params.put("metadata_fields_stripped", String.valueOf(metadataFieldsStripped));

        ProvenanceRecord anonProv = ProvenanceRecord.of(
                "mpeg-o anonymizer v0.4", params, List.of(), List.of());

        List<ProvenanceRecord> prov = new ArrayList<>(source.provenanceRecords());
        prov.add(anonProv);

        FeatureFlags flags = source.featureFlags().with(FeatureFlags.OPT_ANONYMIZED);

        // Filter identifications (remove SAAV if redacted)
        List<Identification> idents = source.identifications();
        if (policy.redactSaavSpectra()) {
            idents = idents.stream()
                    .filter(id -> !isSaav(id.chemicalEntity()))
                    .toList();
        }

        SpectralDataset result = SpectralDataset.create(outputPath, title,
                source.isaInvestigationId(), anonymizedRuns, idents,
                source.quantifications(), prov, flags);

        return new AnonymizationResult(result, spectraRedacted, intensitiesZeroed,
                mzValuesCoarsened, csValuesCoarsened, metabolitesMasked,
                metadataFieldsStripped);
    }

    static boolean isSaav(String chemicalEntity) {
        if (chemicalEntity == null) return false;
        String upper = chemicalEntity.toUpperCase();
        return upper.contains("SAAV") || upper.contains("VARIANT");
    }

    static double quantileThreshold(double[] data, double quantile) {
        double[] sorted = data.clone();
        Arrays.sort(sorted);
        int idx = (int) (quantile * (sorted.length - 1));
        return sorted[Math.min(idx, sorted.length - 1)];
    }

    static Map<String, Double> loadDefaultPrevalence() {
        Map<String, Double> table = new LinkedHashMap<>();
        try (InputStream is = Anonymizer.class.getResourceAsStream(
                "/data/metabolite_prevalence.json")) {
            if (is == null) return table;
            String json = new String(is.readAllBytes(), StandardCharsets.UTF_8);
            // Simple JSON parse for {"key": value, ...}
            for (String line : json.split("\n")) {
                line = line.strip();
                if (line.startsWith("\"CHEBI:")) {
                    int colonIdx = line.indexOf(':');
                    // Find the key
                    int keyEnd = line.indexOf('"', 1);
                    String key = line.substring(1, keyEnd);
                    // Find the value
                    int valStart = line.indexOf(':', keyEnd) + 1;
                    String valStr = line.substring(valStart).replaceAll("[,\\s]", "");
                    try {
                        table.put(key, Double.parseDouble(valStr));
                    } catch (NumberFormatException ignored) {}
                }
            }
        } catch (IOException ignored) {}
        return table;
    }
}
