/*
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */
package com.dtwthalion.mpgo.importers;

import com.dtwthalion.mpgo.Feature;
import com.dtwthalion.mpgo.Identification;
import com.dtwthalion.mpgo.Quantification;

import java.io.BufferedReader;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * mzTab importer — v0.9 M60.
 *
 * <p>Tab-separated text reader that maps PSM / PRT / SML rows into
 * {@link Identification} and {@link Quantification} records suitable
 * for inclusion in an {@code .mpgo} container's compound
 * identification / quantification datasets.</p>
 *
 * <p>Mode dispatch follows the {@code MTD mzTab-version} line per
 * HANDOFF binding decision 47:
 * <ul>
 *   <li>{@code "1.0"} — proteomics dialect (PSM/PRT)</li>
 *   <li>{@code "2.0.0-M"} — metabolomics dialect (SML)</li>
 * </ul></p>
 *
 * <p>API status: Provisional (v0.9 M60).</p>
 *
 * <p>Cross-language equivalents: Python
 * {@code mpeg_o.importers.mztab}, Objective-C
 * {@code MPGOMzTabReader}.</p>
 *
 * @since 0.9
 */
public final class MzTabReader {

    /** In-memory representation of a parsed mzTab document. */
    public record MzTabImport(
        String version,
        String description,
        String title,
        Map<Integer, String> msRunLocations,
        List<String> sampleRefs,
        List<String> software,
        List<String> searchEngines,
        List<Identification> identifications,
        List<Quantification> quantifications,
        List<Feature> features,
        String sourcePath
    ) {
        public boolean isMetabolomics() { return version.endsWith("-M"); }
    }

    /** Raised when the mzTab document is structurally invalid. */
    public static final class MzTabParseException extends IOException {
        private static final long serialVersionUID = 1L;
        public MzTabParseException(String msg) { super(msg); }
    }

    private static final Pattern MS_RUN_RE   = Pattern.compile("^ms_run\\[(\\d+)\\]-location$");
    private static final Pattern ASSAY_RE    = Pattern.compile("^assay\\[(\\d+)\\]-sample_ref$");
    private static final Pattern SV_RE       = Pattern.compile("^study_variable\\[(\\d+)\\]-description$");
    private static final Pattern SOFTWARE_RE = Pattern.compile("^software\\[\\d+\\](?:-setting\\[\\d+\\])?$");
    private static final Pattern SE_SCORE_RE = Pattern.compile("^psm_search_engine_score\\[\\d+\\]$");
    private static final Pattern SPECTRA_REF_RE = Pattern.compile("^ms_run\\[(\\d+)\\]:(.+)$");
    private static final Pattern PRT_ABUND_RE = Pattern.compile("^protein_abundance_assay\\[(\\d+)\\]$");
    private static final Pattern SML_ABUND_RE = Pattern.compile("^abundance_study_variable\\[(\\d+)\\]$");
    private static final Pattern PSM_SCORE_COL_RE = Pattern.compile("^search_engine_score\\[\\d+\\]$");
    private static final Pattern PEP_ASSAY_RE = Pattern.compile("^peptide_abundance_assay\\[(\\d+)\\]$");
    private static final Pattern PEP_SV_RE = Pattern.compile("^peptide_abundance_study_variable\\[(\\d+)\\]$");
    private static final Pattern SMF_ASSAY_RE = Pattern.compile("^abundance_assay\\[(\\d+)\\]$");

    private MzTabReader() {}

    /** Parse an mzTab file. */
    public static MzTabImport read(Path path) throws IOException {
        if (!Files.isRegularFile(path)) {
            throw new MzTabParseException("mzTab file not found: " + path);
        }

        String version = "";
        String description = "";
        String title = "";
        Map<Integer, String> msRunLocations = new LinkedHashMap<>();
        Map<Integer, String> assayToSample  = new LinkedHashMap<>();
        Map<Integer, String> studyVariables = new LinkedHashMap<>();
        List<String> software = new ArrayList<>();
        List<String> searchEngines = new ArrayList<>();
        List<Identification> identifications = new ArrayList<>();
        List<Quantification> quantifications = new ArrayList<>();
        List<Feature> features = new ArrayList<>();

        List<String> psmHeader = null;
        List<String> prtHeader = null;
        List<String> smlHeader = null;
        List<String> pepHeader = null;
        List<String> smfHeader = null;
        List<String> smeHeader = null;

        try (BufferedReader br = Files.newBufferedReader(path)) {
            String raw;
            while ((raw = br.readLine()) != null) {
                String line = raw.replace("\r", "");
                if (line.isEmpty() || line.startsWith("#")) continue;
                String[] cols = line.split("\t", -1);
                String prefix = cols[0];
                switch (prefix) {
                    case "COM":
                        break;
                    case "MTD": {
                        if (cols.length < 3) break;
                        String key = cols[1];
                        StringBuilder valSb = new StringBuilder();
                        for (int i = 2; i < cols.length; i++) {
                            if (i > 2) valSb.append('\t');
                            valSb.append(cols[i]);
                        }
                        String value = valSb.toString();
                        switch (key) {
                            case "mzTab-version": version = value; continue;
                            case "description": case "mzTab-description": description = value; continue;
                            case "mzTab-ID": case "title": title = value; continue;
                            default: break;
                        }
                        Matcher m;
                        if ((m = MS_RUN_RE.matcher(key)).matches()) {
                            msRunLocations.put(Integer.parseInt(m.group(1)), value);
                        } else if ((m = ASSAY_RE.matcher(key)).matches()) {
                            assayToSample.put(Integer.parseInt(m.group(1)), value);
                        } else if ((m = SV_RE.matcher(key)).matches()) {
                            studyVariables.put(Integer.parseInt(m.group(1)), value);
                        } else if (SOFTWARE_RE.matcher(key).matches()) {
                            software.add(value);
                        } else if (SE_SCORE_RE.matcher(key).matches()) {
                            searchEngines.add(value);
                        }
                        break;
                    }
                    case "PSH": psmHeader = List.of(cols); break;
                    case "PSM":
                        if (psmHeader != null) {
                            handlePsm(psmHeader, cols, msRunLocations, identifications);
                        }
                        break;
                    case "PRH": prtHeader = List.of(cols); break;
                    case "PRT":
                        if (prtHeader != null) {
                            handlePrt(prtHeader, cols, assayToSample, quantifications);
                        }
                        break;
                    case "SMH": smlHeader = List.of(cols); break;
                    case "SML":
                        if (smlHeader != null) {
                            handleSml(smlHeader, cols, studyVariables,
                                       identifications, quantifications);
                        }
                        break;
                    case "PEH": pepHeader = List.of(cols); break;
                    case "PEP":
                        if (pepHeader != null) {
                            handlePep(pepHeader, cols, msRunLocations,
                                       assayToSample, studyVariables,
                                       features);
                        }
                        break;
                    case "SFH": smfHeader = List.of(cols); break;
                    case "SMF":
                        if (smfHeader != null) {
                            handleSmf(smfHeader, cols, assayToSample, features);
                        }
                        break;
                    case "SEH": smeHeader = List.of(cols); break;
                    case "SME":
                        if (smeHeader != null) {
                            handleSme(smeHeader, cols, msRunLocations,
                                       identifications, features);
                        }
                        break;
                    default:
                        break;
                }
            }
        }

        if (version.isEmpty()) {
            throw new MzTabParseException(path + ": missing MTD mzTab-version line");
        }

        List<String> sampleRefs = new ArrayList<>();
        if (!assayToSample.isEmpty()) sampleRefs.addAll(assayToSample.values());
        else sampleRefs.addAll(studyVariables.values());

        return new MzTabImport(
            version, description, title,
            Map.copyOf(msRunLocations),
            List.copyOf(sampleRefs),
            List.copyOf(software),
            List.copyOf(searchEngines),
            List.copyOf(identifications),
            List.copyOf(quantifications),
            List.copyOf(features),
            path.toString()
        );
    }

    // ────────────────────────────────────────────────────────────────────
    // Section handlers.
    // ────────────────────────────────────────────────────────────────────

    private static String resolveRunName(int msRunIndex,
                                          Map<Integer, String> locations)
    {
        String location = locations.get(msRunIndex);
        if (location == null || location.isEmpty()) return "run_" + msRunIndex;
        int slash = location.lastIndexOf('/');
        String name = (slash >= 0) ? location.substring(slash + 1) : location;
        int dot = name.lastIndexOf('.');
        if (dot > 0) name = name.substring(0, dot);
        return name.isEmpty() ? "run_" + msRunIndex : name;
    }

    private static int indexOf(List<String> header, String name) {
        for (int i = 0; i < header.size(); i++) {
            if (name.equals(header.get(i))) return i;
        }
        return -1;
    }

    private static String safeGet(String[] cols, int idx) {
        return (idx >= 0 && idx < cols.length) ? cols[idx] : "";
    }

    private static double safeDouble(String s) {
        if (s == null || s.isEmpty()) return 0.0;
        String lc = s.toLowerCase();
        if ("null".equals(lc) || "na".equals(lc) || "n/a".equals(lc) || "nan".equals(lc)) return 0.0;
        try { return Double.parseDouble(s); } catch (NumberFormatException e) { return 0.0; }
    }

    private static Double parseAbundance(String s) {
        if (s == null || s.isEmpty()) return null;
        String lc = s.toLowerCase();
        if ("null".equals(lc) || "na".equals(lc) || "n/a".equals(lc)) return null;
        try { return Double.parseDouble(s); } catch (NumberFormatException e) { return null; }
    }

    private static void handlePsm(List<String> header, String[] cols,
                                    Map<Integer, String> msRunLocations,
                                    List<Identification> out)
    {
        int accIdx = indexOf(header, "accession");
        int seqIdx = indexOf(header, "sequence");
        int seIdx = indexOf(header, "search_engine");
        int psmIdIdx = indexOf(header, "PSM_ID");
        int refIdx = indexOf(header, "spectra_ref");

        String accession = safeGet(cols, accIdx);
        if (accession.isEmpty() || "null".equals(accession)) {
            accession = safeGet(cols, seqIdx);
        }
        if (accession.isEmpty()) return;

        String runName = "imported";
        int spectrumIndex = 0;
        String ref = safeGet(cols, refIdx);
        Matcher m = SPECTRA_REF_RE.matcher(ref);
        if (m.matches()) {
            int runIdx = Integer.parseInt(m.group(1));
            runName = resolveRunName(runIdx, msRunLocations);
            String locator = m.group(2);
            int eq = locator.indexOf('=');
            if (eq >= 0) {
                try { spectrumIndex = Integer.parseInt(locator.substring(eq + 1)); }
                catch (NumberFormatException ignore) { spectrumIndex = 0; }
            }
        }

        double bestScore = 0.0;
        for (int i = 0; i < header.size() && i < cols.length; i++) {
            if (PSM_SCORE_COL_RE.matcher(header.get(i)).matches()) {
                double v = safeDouble(cols[i]);
                if (v > bestScore) bestScore = v;
            }
        }

        List<String> evidence = new ArrayList<>();
        String se = safeGet(cols, seIdx);
        if (!se.isEmpty()) evidence.add(se);
        String psmId = safeGet(cols, psmIdIdx);
        if (!psmId.isEmpty()) evidence.add("PSM_ID=" + psmId);

        out.add(new Identification(runName, spectrumIndex, accession, bestScore, evidence));
    }

    private static void handlePrt(List<String> header, String[] cols,
                                    Map<Integer, String> assayToSample,
                                    List<Quantification> out)
    {
        int accIdx = indexOf(header, "accession");
        String accession = safeGet(cols, accIdx);
        if (accession.isEmpty()) return;
        for (int i = 0; i < header.size() && i < cols.length; i++) {
            Matcher m = PRT_ABUND_RE.matcher(header.get(i));
            if (!m.matches()) continue;
            Double v = parseAbundance(cols[i]);
            if (v == null) continue;
            int assayIdx = Integer.parseInt(m.group(1));
            String sampleRef = assayToSample.getOrDefault(assayIdx, "assay_" + assayIdx);
            out.add(new Quantification(accession, sampleRef, v, ""));
        }
    }

    private static void handleSml(List<String> header, String[] cols,
                                    Map<Integer, String> studyVariables,
                                    List<Identification> identsOut,
                                    List<Quantification> quantsOut)
    {
        int dbIdIdx = indexOf(header, "database_identifier");
        int nameIdx = indexOf(header, "chemical_name");
        int formulaIdx = indexOf(header, "chemical_formula");
        int bestConfIdx = indexOf(header, "best_id_confidence_value");

        String dbId = safeGet(cols, dbIdIdx);
        String name = safeGet(cols, nameIdx);
        String formula = safeGet(cols, formulaIdx);
        String entity = !dbId.isEmpty() ? dbId : (!name.isEmpty() ? name : formula);
        if (entity.isEmpty()) return;
        double best = safeDouble(safeGet(cols, bestConfIdx));

        List<String> evidence = new ArrayList<>();
        if (!name.isEmpty() && !name.equals(entity)) evidence.add("name=" + name);
        if (!formula.isEmpty() && !formula.equals(entity)) evidence.add("formula=" + formula);

        identsOut.add(new Identification("metabolomics", 0, entity, best, evidence));

        for (int i = 0; i < header.size() && i < cols.length; i++) {
            Matcher m = SML_ABUND_RE.matcher(header.get(i));
            if (!m.matches()) continue;
            Double v = parseAbundance(cols[i]);
            if (v == null) continue;
            int svIdx = Integer.parseInt(m.group(1));
            String sampleRef = studyVariables.getOrDefault(svIdx, "study_variable_" + svIdx);
            quantsOut.add(new Quantification(entity, sampleRef, v, ""));
        }
    }

    // ────────────────────────────────────────────────────────────────────
    // M78 handlers: PEP / SMF / SME.
    // ────────────────────────────────────────────────────────────────────

    private static void handlePep(List<String> header, String[] cols,
                                    Map<Integer, String> msRunLocations,
                                    Map<Integer, String> assayToSample,
                                    Map<Integer, String> studyVariables,
                                    List<Feature> out)
    {
        int seqIdx = indexOf(header, "sequence");
        int accIdx = indexOf(header, "accession");
        int chargeIdx = indexOf(header, "charge");
        int mzIdx = indexOf(header, "mass_to_charge");
        int rtIdx = indexOf(header, "retention_time");
        int refIdx = indexOf(header, "spectra_ref");

        String sequence = safeGet(cols, seqIdx);
        String accession = safeGet(cols, accIdx);
        String entity = !sequence.isEmpty() ? sequence : accession;
        if (entity.isEmpty()) return;

        String ref = safeGet(cols, refIdx);
        String runName = "imported";
        Matcher m = SPECTRA_REF_RE.matcher(ref);
        if (m.matches()) {
            runName = resolveRunName(Integer.parseInt(m.group(1)), msRunLocations);
        }

        int charge = 0;
        try { charge = Integer.parseInt(safeGet(cols, chargeIdx)); }
        catch (NumberFormatException ignored) { charge = 0; }
        double mz = safeDouble(safeGet(cols, mzIdx));
        double rt = safeDouble(safeGet(cols, rtIdx));

        Map<String, Double> abundances = new LinkedHashMap<>();
        for (int i = 0; i < header.size() && i < cols.length; i++) {
            Matcher mm = PEP_ASSAY_RE.matcher(header.get(i));
            if (mm.matches()) {
                Double v = parseAbundance(cols[i]);
                if (v == null) continue;
                int assayIdx = Integer.parseInt(mm.group(1));
                abundances.put(assayToSample.getOrDefault(assayIdx, "assay_" + assayIdx), v);
                continue;
            }
            mm = PEP_SV_RE.matcher(header.get(i));
            if (mm.matches()) {
                Double v = parseAbundance(cols[i]);
                if (v == null) continue;
                int svIdx = Integer.parseInt(mm.group(1));
                abundances.put(studyVariables.getOrDefault(svIdx, "study_variable_" + svIdx), v);
            }
        }

        List<String> evidenceRefs = new ArrayList<>();
        if (!ref.isEmpty() && !"null".equals(ref)) evidenceRefs.add(ref);

        String featureId = "pep_" + (out.size() + 1);
        out.add(new Feature(featureId, runName, entity, rt, mz, charge, "",
                            abundances, evidenceRefs));
    }

    private static void handleSmf(List<String> header, String[] cols,
                                    Map<Integer, String> assayToSample,
                                    List<Feature> out)
    {
        int idIdx = indexOf(header, "SMF_ID");
        int smeRefsIdx = indexOf(header, "SME_ID_REFS");
        int adductIdx = indexOf(header, "adduct_ion");
        int mzIdx = indexOf(header, "exp_mass_to_charge");
        int chargeIdx = indexOf(header, "charge");
        int rtIdx = indexOf(header, "retention_time_in_seconds");

        String smfId = safeGet(cols, idIdx);
        if (smfId.isEmpty()) return;

        String smeRefsRaw = safeGet(cols, smeRefsIdx);
        List<String> smeRefs = new ArrayList<>();
        if (!smeRefsRaw.isEmpty() && !"null".equalsIgnoreCase(smeRefsRaw)) {
            for (String part : smeRefsRaw.split("\\|")) {
                if (!part.isEmpty() && !"null".equalsIgnoreCase(part)) smeRefs.add(part);
            }
        }

        String adduct = safeGet(cols, adductIdx);
        if ("null".equalsIgnoreCase(adduct)) adduct = "";
        double mz = safeDouble(safeGet(cols, mzIdx));
        double rt = safeDouble(safeGet(cols, rtIdx));
        int charge = 0;
        try { charge = Integer.parseInt(safeGet(cols, chargeIdx)); }
        catch (NumberFormatException ignored) { charge = 0; }

        Map<String, Double> abundances = new LinkedHashMap<>();
        for (int i = 0; i < header.size() && i < cols.length; i++) {
            Matcher mm = SMF_ASSAY_RE.matcher(header.get(i));
            if (!mm.matches()) continue;
            Double v = parseAbundance(cols[i]);
            if (v == null) continue;
            int assayIdx = Integer.parseInt(mm.group(1));
            abundances.put(assayToSample.getOrDefault(assayIdx, "assay_" + assayIdx), v);
        }

        String entity = smeRefs.isEmpty() ? smfId : smeRefs.get(0);
        out.add(new Feature("smf_" + smfId, "metabolomics", entity,
                            rt, mz, charge, adduct, abundances, smeRefs));
    }

    private static void handleSme(List<String> header, String[] cols,
                                    Map<Integer, String> msRunLocations,
                                    List<Identification> identsOut,
                                    List<Feature> features)
    {
        int idIdx = indexOf(header, "SME_ID");
        int dbIdx = indexOf(header, "database_identifier");
        int nameIdx = indexOf(header, "chemical_name");
        int formulaIdx = indexOf(header, "chemical_formula");
        int refIdx = indexOf(header, "spectra_ref");
        int rankIdx = indexOf(header, "rank");

        String smeId = safeGet(cols, idIdx);
        if (smeId.isEmpty()) return;

        String db = safeGet(cols, dbIdx);
        String chemName = safeGet(cols, nameIdx);
        String formula = safeGet(cols, formulaIdx);
        String entity = !db.isEmpty() && !"null".equalsIgnoreCase(db) ? db
            : (!chemName.isEmpty() && !"null".equalsIgnoreCase(chemName) ? chemName
               : (!formula.isEmpty() && !"null".equalsIgnoreCase(formula) ? formula : smeId));

        int rank = 1;
        try { rank = Integer.parseInt(safeGet(cols, rankIdx)); }
        catch (NumberFormatException ignored) { rank = 1; }
        double confidence = rank > 0 ? 1.0 / (double) rank : 0.0;

        String runName = "metabolomics";
        int spectrumIndex = 0;
        String ref = safeGet(cols, refIdx);
        Matcher m = SPECTRA_REF_RE.matcher(ref);
        if (m.matches()) {
            runName = resolveRunName(Integer.parseInt(m.group(1)), msRunLocations);
            String locator = m.group(2);
            int eq = locator.indexOf('=');
            if (eq >= 0) {
                try { spectrumIndex = Integer.parseInt(locator.substring(eq + 1)); }
                catch (NumberFormatException ignored) { spectrumIndex = 0; }
            }
        }

        List<String> evidence = new ArrayList<>();
        evidence.add("SME_ID=" + smeId);
        if (!chemName.isEmpty() && !chemName.equals(entity) && !"null".equalsIgnoreCase(chemName)) {
            evidence.add("name=" + chemName);
        }
        if (!formula.isEmpty() && !formula.equals(entity) && !"null".equalsIgnoreCase(formula)) {
            evidence.add("formula=" + formula);
        }

        identsOut.add(new Identification(runName, spectrumIndex, entity, confidence, evidence));

        // Back-fill features that referenced this SME so their
        // chemicalEntity gets upgraded from the placeholder SME_ID.
        for (int i = 0; i < features.size(); i++) {
            Feature f = features.get(i);
            if (f.evidenceRefs().contains(smeId) && f.chemicalEntity().equals(smeId)) {
                features.set(i, new Feature(
                    f.featureId(), f.runName(), entity,
                    f.retentionTimeSeconds(), f.expMassToCharge(),
                    f.charge(), f.adductIon(),
                    f.abundances(), f.evidenceRefs()
                ));
            }
        }
    }
}
