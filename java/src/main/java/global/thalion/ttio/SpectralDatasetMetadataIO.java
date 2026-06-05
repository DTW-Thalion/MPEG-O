/*
 * TTI-O Java Implementation
 * Copyright (c) 2026 The Thalion Initiative
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio;

import global.thalion.ttio.hdf5.Hdf5CompoundIO;
import global.thalion.ttio.hdf5.Hdf5Group;

import java.util.*;

/** Package-private helper extracted from {@link SpectralDataset} (P3.10).
 *  Pure code movement; no behavior change. */
final class SpectralDatasetMetadataIO {

    private SpectralDatasetMetadataIO() { }

    /** Logger for soft-FK warnings (Sample.subjectExternalId not in
     *  Subject list). Spec §4.4: this is a WARNING, not an error. */
    static final java.util.logging.Logger STAGE6_LOG =
        java.util.logging.Logger.getLogger(SpectralDataset.class.getName());

    static void writeIdentifications(Hdf5Group study,
                                              List<Identification> idents) {
        // Native compound dataset matching format-spec §6.1
        Hdf5CompoundIO.writeCompoundDataset(study, "identifications",
                Hdf5CompoundIO.identificationSchema(),
                idents.size(),
                (row, pool) -> new Object[]{
                        pool.addString(idents.get(row).runName()),
                        idents.get(row).spectrumIndex(),
                        pool.addString(idents.get(row).chemicalEntity()),
                        idents.get(row).confidenceScore(),
                        pool.addString(idents.get(row).evidenceChainJson())
                });
        // identifications_json mirror retired. Java reads
        // VL_STRING from the compound directly via Unsafe deref now,
        // so the JSON shadow is dead weight on the HDF5 fast path.
    }

    static List<Identification> readIdentifications(Hdf5Group study) {
        // prefer the compound (canonical) — VL_STRING reads
        // work via Unsafe deref now. Fall back to legacy JSON mirror
        // only when the compound is absent (older Java-written files
        // that were JSON-only or unusual layouts).
        if (study.hasChild("identifications")) {
            List<Object[]> rows = Hdf5CompoundIO.readCompoundFull(
                    study, "identifications", Hdf5CompoundIO.identificationSchema());
            List<Identification> out = new ArrayList<>(rows.size());
            for (Object[] r : rows) {
                out.add(new Identification(
                        (String) r[0], (Integer) r[1], (String) r[2],
                        (Double) r[3], MiniJson.parseArrayOfStrings((String) r[4])));
            }
            return out;
        }
        if (study.hasAttribute("identifications_json")) {
            return parseIdentificationsJson(study.readStringAttribute("identifications_json"));
        }
        return List.of();
    }

    static void writeQuantifications(Hdf5Group study,
                                              List<Quantification> quants) {
        Hdf5CompoundIO.writeCompoundDataset(study, "quantifications",
                Hdf5CompoundIO.quantificationSchema(),
                quants.size(),
                (row, pool) -> new Object[]{
                        pool.addString(quants.get(row).chemicalEntity()),
                        pool.addString(quants.get(row).sampleRef()),
                        quants.get(row).abundance(),
                        pool.addString(quants.get(row).normalizationMethod() != null
                                ? quants.get(row).normalizationMethod() : "")
                });
        // Optional sidecar `quantification_units` JSON-array attribute on
        // the study group: one string per row, parallel to the compound
        // dataset above. Emitted only when at least one quantification
        // carries a non-empty unit; absent on legacy files (units default
        // to ""). JSON is used here rather than a VL-string dataset to
        // keep the reader path single-attribute-read (Hdf5Group doesn't
        // expose a string-dataset helper today).
        boolean anyUnit = false;
        for (Quantification q : quants) {
            if (q.unit() != null && !q.unit().isEmpty()) { anyUnit = true; break; }
        }
        if (anyUnit) {
            StringBuilder sb = new StringBuilder("[");
            for (int i = 0; i < quants.size(); i++) {
                if (i > 0) sb.append(",");
                String u = quants.get(i).unit();
                sb.append("\"").append((u == null ? "" : u)
                        .replace("\\", "\\\\").replace("\"", "\\\"")).append("\"");
            }
            sb.append("]");
            study.setStringAttribute("quantification_units", sb.toString());
        }
        // quantifications_json mirror retired (see writeIdentifications).
    }

    static List<Quantification> readQuantifications(Hdf5Group study) {
        // compound first (canonical); JSON fallback for legacy.
        if (study.hasChild("quantifications")) {
            List<Object[]> rows = Hdf5CompoundIO.readCompoundFull(
                    study, "quantifications", Hdf5CompoundIO.quantificationSchema());
            List<String> units = study.hasAttribute("quantification_units")
                    ? MiniJson.parseArrayOfStrings(
                          study.readStringAttribute("quantification_units"))
                    : null;
            List<Quantification> out = new ArrayList<>(rows.size());
            for (int i = 0; i < rows.size(); i++) {
                Object[] r = rows.get(i);
                String norm = (String) r[3];
                if (norm != null && norm.isEmpty()) norm = null;
                String unit = (units != null && i < units.size()) ? units.get(i) : "";
                out.add(new Quantification(
                        (String) r[0], (String) r[1], (Double) r[2], norm, unit));
            }
            return out;
        }
        if (study.hasAttribute("quantifications_json")) {
            return parseQuantificationsJson(study.readStringAttribute("quantifications_json"));
        }
        return List.of();
    }

    static void writeProvenance(Hdf5Group study,
                                         List<ProvenanceRecord> records) {
        Hdf5CompoundIO.writeCompoundDataset(study, "provenance",
                Hdf5CompoundIO.provenanceSchema(),
                records.size(),
                (row, pool) -> new Object[]{
                        records.get(row).timestampUnix(),
                        pool.addString(records.get(row).software()),
                        pool.addString(records.get(row).parametersJson()),
                        pool.addString(records.get(row).inputRefsJson()),
                        pool.addString(records.get(row).outputRefsJson())
                });
        // study-level provenance_json mirror retired
        // (see writeIdentifications). The per-run provenance_json
        // attribute on /study/ms_runs/<name>/ is a different layer
        // and is signed by signatures.py — that one stays.
    }

    static List<ProvenanceRecord> readProvenance(Hdf5Group study) {
        // compound first (canonical); JSON fallback for legacy.
        if (study.hasChild("provenance")) {
            List<Object[]> rows = Hdf5CompoundIO.readCompoundFull(
                    study, "provenance", Hdf5CompoundIO.provenanceSchema());
            List<ProvenanceRecord> out = new ArrayList<>(rows.size());
            for (Object[] r : rows) {
                out.add(new ProvenanceRecord(
                        (Long) r[0], (String) r[1],
                        MiniJson.parseStringMap((String) r[2]),
                        MiniJson.parseArrayOfStrings((String) r[3]),
                        MiniJson.parseArrayOfStrings((String) r[4])));
            }
            return out;
        }
        if (study.hasAttribute("provenance_json")) {
            return parseProvenanceJson(study.readStringAttribute("provenance_json"));
        }
        return List.of();
    }

    static List<Identification> readIdentificationsFromJson(
            global.thalion.ttio.providers.StorageGroup study) {
        if (!study.hasAttribute("identifications_json")) return List.of();
        Object v = study.getAttribute("identifications_json");
        return v != null ? parseIdentificationsJson(v.toString()) : List.of();
    }

    static List<Quantification> readQuantificationsFromJson(
            global.thalion.ttio.providers.StorageGroup study) {
        if (!study.hasAttribute("quantifications_json")) return List.of();
        Object v = study.getAttribute("quantifications_json");
        return v != null ? parseQuantificationsJson(v.toString()) : List.of();
    }

    static List<ProvenanceRecord> readProvenanceFromJson(
            global.thalion.ttio.providers.StorageGroup study) {
        if (!study.hasAttribute("provenance_json")) return List.of();
        Object v = study.getAttribute("provenance_json");
        return v != null ? parseProvenanceJson(v.toString()) : List.of();
    }

    static String buildIdentificationsJson(List<Identification> idents) {
        StringBuilder json = new StringBuilder("[");
        for (int i = 0; i < idents.size(); i++) {
            if (i > 0) json.append(',');
            Identification id = idents.get(i);
            json.append('{')
                .append("\"run_name\":").append(MiniJson.quote(id.runName()))
                .append(",\"spectrum_index\":").append(id.spectrumIndex())
                .append(",\"chemical_entity\":").append(MiniJson.quote(id.chemicalEntity()))
                .append(",\"confidence_score\":").append(id.confidenceScore())
                .append(",\"evidence_chain\":").append(
                        id.evidenceChainJson() == null || id.evidenceChainJson().isEmpty()
                                ? "[]" : id.evidenceChainJson())
                .append('}');
        }
        json.append(']');
        return json.toString();
    }

    static String buildQuantificationsJson(List<Quantification> quants) {
        StringBuilder json = new StringBuilder("[");
        for (int i = 0; i < quants.size(); i++) {
            if (i > 0) json.append(',');
            Quantification q = quants.get(i);
            json.append('{')
                .append("\"chemical_entity\":").append(MiniJson.quote(q.chemicalEntity()))
                .append(",\"sample_ref\":").append(MiniJson.quote(q.sampleRef()))
                .append(",\"abundance\":").append(q.abundance());
            if (q.normalizationMethod() != null) {
                json.append(",\"normalization_method\":").append(MiniJson.quote(q.normalizationMethod()));
            }
            json.append('}');
        }
        json.append(']');
        return json.toString();
    }

    static String buildProvenanceJson(List<ProvenanceRecord> records) {
        StringBuilder json = new StringBuilder("[");
        for (int i = 0; i < records.size(); i++) {
            if (i > 0) json.append(',');
            ProvenanceRecord r = records.get(i);
            json.append('{')
                .append("\"timestamp_unix\":").append(r.timestampUnix())
                .append(",\"software\":").append(MiniJson.quote(r.software()))
                .append(",\"parameters\":").append(nonEmptyJson(r.parametersJson(), "{}"))
                .append(",\"input_refs\":").append(nonEmptyJson(r.inputRefsJson(), "[]"))
                .append(",\"output_refs\":").append(nonEmptyJson(r.outputRefsJson(), "[]"))
                .append('}');
        }
        json.append(']');
        return json.toString();
    }

    static List<Identification> parseIdentificationsJson(String blob) {
        List<Identification> out = new ArrayList<>();
        for (Map<String, Object> r : MiniJson.parseArrayOfObjects(blob)) {
            String runName = MiniJson.getString(r, "run_name", "");
            int idx = (int) MiniJson.getLong(r, "spectrum_index", 0);
            String chem = MiniJson.getString(r, "chemical_entity", "");
            double conf = MiniJson.getDouble(r, "confidence_score", 0.0);
            Object ev = r.get("evidence_chain");
            List<String> evidenceChain = ev instanceof List<?> list
                    ? list.stream().map(Object::toString).toList()
                    : List.of();
            out.add(new Identification(runName, idx, chem, conf, evidenceChain));
        }
        return out;
    }

    static List<Quantification> parseQuantificationsJson(String blob) {
        List<Quantification> out = new ArrayList<>();
        for (Map<String, Object> r : MiniJson.parseArrayOfObjects(blob)) {
            String chem = MiniJson.getString(r, "chemical_entity", "");
            String sample = MiniJson.getString(r, "sample_ref", "");
            double abund = MiniJson.getDouble(r, "abundance", 0.0);
            String norm = r.containsKey("normalization_method")
                    ? MiniJson.getString(r, "normalization_method", null)
                    : null;
            if (norm != null && norm.isEmpty()) norm = null;
            String unit = MiniJson.getString(r, "unit", "");
            out.add(new Quantification(chem, sample, abund, norm, unit));
        }
        return out;
    }

    static List<ProvenanceRecord> parseProvenanceJson(String blob) {
        List<ProvenanceRecord> out = new ArrayList<>();
        for (Map<String, Object> r : MiniJson.parseArrayOfObjects(blob)) {
            long ts = MiniJson.getLong(r, "timestamp_unix", 0);
            String software = MiniJson.getString(r, "software", "");
            Object paramsObj = r.get("parameters");
            Map<String, String> params;
            if (paramsObj instanceof Map<?, ?> m) {
                Map<String, String> tmp = new java.util.LinkedHashMap<>();
                for (Map.Entry<?, ?> e : m.entrySet()) {
                    tmp.put(e.getKey().toString(),
                            e.getValue() == null ? "" : e.getValue().toString());
                }
                params = tmp;
            } else {
                params = Map.of();
            }
            Object inRefsObj = r.get("input_refs");
            List<String> inRefs = inRefsObj instanceof List<?> l
                    ? l.stream().map(o -> o == null ? "" : o.toString()).toList()
                    : List.of();
            Object outRefsObj = r.get("output_refs");
            List<String> outRefs = outRefsObj instanceof List<?> l
                    ? l.stream().map(o -> o == null ? "" : o.toString()).toList()
                    : List.of();
            out.add(new ProvenanceRecord(ts, software, params, inRefs, outRefs));
        }
        return out;
    }

    static String nonEmptyJson(String s, String fallback) {
        return s == null || s.isEmpty() ? fallback : s;
    }

    /** Pre-write validation per spec §4.4:
     *  duplicate {@code Subject.externalId} or {@code Sample.sampleId}
     *  raises {@link IllegalArgumentException}; soft-FK mismatch
     *  ({@code Sample.subjectExternalId} not found in Subject list)
     *  logs WARNING but does not fail. */
    static void validateSubjectsAndSamples(
            List<Subject> subjects, List<Sample> samples) {
        java.util.Set<String> seenSubjects = new java.util.HashSet<>();
        for (Subject s : subjects) {
            if (!seenSubjects.add(s.externalId())) {
                throw new IllegalArgumentException(
                    "duplicate Subject.externalId: " + s.externalId());
            }
        }
        java.util.Set<String> seenSamples = new java.util.HashSet<>();
        for (Sample s : samples) {
            if (!seenSamples.add(s.sampleId())) {
                throw new IllegalArgumentException(
                    "duplicate Sample.sampleId: " + s.sampleId());
            }
        }
        for (Sample s : samples) {
            String fk = s.subjectExternalId();
            if (fk == null || fk.isEmpty()) continue;
            if (!seenSubjects.contains(fk)) {
                STAGE6_LOG.warning(
                    "Sample '" + s.sampleId() + "' references unknown "
                    + "Subject.externalId '" + fk + "' — soft-FK "
                    + "mismatch, writing anyway (spec §4.4).");
            }
        }
    }

    /** HDF5 fast path: write {@code /study/subjects/<external_id>/}
     *  per-row groups with typed attributes. Absent group when the
     *  list is empty (spec §5 empty-case rule). */
    static void writeSubjects(Hdf5Group study, List<Subject> subjects) {
        if (subjects == null || subjects.isEmpty()) return;
        try (Hdf5Group subjectsGroup = study.createGroup("subjects")) {
            for (Subject s : subjects) {
                try (Hdf5Group row = subjectsGroup.createGroup(s.externalId())) {
                    row.setStringAttribute("external_id", s.externalId());
                    if (!s.project().isEmpty())
                        row.setStringAttribute("project", s.project());
                    if (!s.sex().isEmpty())
                        row.setStringAttribute("sex", s.sex());
                    row.setIntegerAttribute("birth_year", s.birthYear());
                    row.setStringAttribute("attributes_json", s.attributesJson());
                }
            }
        }
    }

    /** HDF5 fast path: write {@code /study/samples/<sample_id>/}
     *  per-row groups with typed attributes. Absent group when the
     *  list is empty. */
    static void writeSamples(Hdf5Group study, List<Sample> samples) {
        if (samples == null || samples.isEmpty()) return;
        try (Hdf5Group samplesGroup = study.createGroup("samples")) {
            for (Sample s : samples) {
                try (Hdf5Group row = samplesGroup.createGroup(s.sampleId())) {
                    row.setStringAttribute("sample_id", s.sampleId());
                    if (!s.subjectExternalId().isEmpty())
                        row.setStringAttribute(
                            "subject_external_id", s.subjectExternalId());
                    if (!s.sampleKind().isEmpty())
                        row.setStringAttribute("sample_kind", s.sampleKind());
                    row.setIntegerAttribute("collected_at", s.collectedAt());
                    row.setStringAttribute("attributes_json", s.attributesJson());
                }
            }
        }
    }

    /** Provider-agnostic mirror of {@link #writeSubjects}. */
    static void writeSubjectsViaProvider(
            global.thalion.ttio.providers.StorageGroup study,
            List<Subject> subjects) {
        if (subjects == null || subjects.isEmpty()) return;
        try (var subjectsGroup = study.createGroup("subjects")) {
            for (Subject s : subjects) {
                try (var row = subjectsGroup.createGroup(s.externalId())) {
                    row.setAttribute("external_id", s.externalId());
                    if (!s.project().isEmpty())
                        row.setAttribute("project", s.project());
                    if (!s.sex().isEmpty())
                        row.setAttribute("sex", s.sex());
                    row.setAttribute("birth_year", s.birthYear());
                    row.setAttribute("attributes_json", s.attributesJson());
                }
            }
        }
    }

    /** Provider-agnostic mirror of {@link #writeSamples}. */
    static void writeSamplesViaProvider(
            global.thalion.ttio.providers.StorageGroup study,
            List<Sample> samples) {
        if (samples == null || samples.isEmpty()) return;
        try (var samplesGroup = study.createGroup("samples")) {
            for (Sample s : samples) {
                try (var row = samplesGroup.createGroup(s.sampleId())) {
                    row.setAttribute("sample_id", s.sampleId());
                    if (!s.subjectExternalId().isEmpty())
                        row.setAttribute(
                            "subject_external_id", s.subjectExternalId());
                    if (!s.sampleKind().isEmpty())
                        row.setAttribute("sample_kind", s.sampleKind());
                    row.setAttribute("collected_at", s.collectedAt());
                    row.setAttribute("attributes_json", s.attributesJson());
                }
            }
        }
    }

    /** HDF5 fast path: read {@code /study/subjects/<external_id>/}
     *  groups back into {@link Subject} instances. Empty list when
     *  the group is absent (pre-Stage-6 files). */
    static List<Subject> readSubjects(Hdf5Group study) {
        if (!study.hasChild("subjects")) return List.of();
        List<Subject> out = new ArrayList<>();
        try (Hdf5Group subjectsGroup = study.openGroup("subjects")) {
            for (String name : subjectsGroup.childNames()) {
                try (Hdf5Group row = subjectsGroup.openGroup(name)) {
                    String externalId = row.hasAttribute("external_id")
                        ? row.readStringAttribute("external_id") : name;
                    String project = row.hasAttribute("project")
                        ? row.readStringAttribute("project") : "";
                    String sex = row.hasAttribute("sex")
                        ? row.readStringAttribute("sex") : "";
                    long birthYear = row.readIntegerAttribute("birth_year", 0L);
                    Map<String, String> attrs = row.hasAttribute("attributes_json")
                        ? MiniJson.parseStringMap(row.readStringAttribute("attributes_json"))
                        : Map.of();
                    out.add(new Subject(externalId, project, sex, birthYear, attrs));
                }
            }
        }
        return out;
    }

    /** HDF5 fast path: read {@code /study/samples/<sample_id>/}
     *  groups back into {@link Sample} instances. */
    static List<Sample> readSamples(Hdf5Group study) {
        if (!study.hasChild("samples")) return List.of();
        List<Sample> out = new ArrayList<>();
        try (Hdf5Group samplesGroup = study.openGroup("samples")) {
            for (String name : samplesGroup.childNames()) {
                try (Hdf5Group row = samplesGroup.openGroup(name)) {
                    String sampleId = row.hasAttribute("sample_id")
                        ? row.readStringAttribute("sample_id") : name;
                    String subjectExternalId = row.hasAttribute("subject_external_id")
                        ? row.readStringAttribute("subject_external_id") : "";
                    String sampleKind = row.hasAttribute("sample_kind")
                        ? row.readStringAttribute("sample_kind") : "";
                    long collectedAt = row.readIntegerAttribute("collected_at", 0L);
                    Map<String, String> attrs = row.hasAttribute("attributes_json")
                        ? MiniJson.parseStringMap(row.readStringAttribute("attributes_json"))
                        : Map.of();
                    out.add(new Sample(sampleId, subjectExternalId,
                            sampleKind, collectedAt, attrs));
                }
            }
        }
        return out;
    }

    /** Provider-agnostic mirror of {@link #readSubjects}. */
    static List<Subject> readSubjectsFromProvider(
            global.thalion.ttio.providers.StorageGroup study) {
        if (!study.hasChild("subjects")) return List.of();
        List<Subject> out = new ArrayList<>();
        try (var subjectsGroup = study.openGroup("subjects")) {
            for (String name : subjectsGroup.childNames()) {
                try (var row = subjectsGroup.openGroup(name)) {
                    String externalId = readStringAttrOrDefault(
                        row, "external_id", name);
                    String project = readStringAttrOrDefault(row, "project", "");
                    String sex = readStringAttrOrDefault(row, "sex", "");
                    long birthYear = readLongAttrOrDefault(row, "birth_year", 0L);
                    Map<String, String> attrs = row.hasAttribute("attributes_json")
                        ? MiniJson.parseStringMap(
                            readStringAttrOrDefault(row, "attributes_json", "{}"))
                        : Map.of();
                    out.add(new Subject(externalId, project, sex, birthYear, attrs));
                }
            }
        }
        return out;
    }

    /** Provider-agnostic mirror of {@link #readSamples}. */
    static List<Sample> readSamplesFromProvider(
            global.thalion.ttio.providers.StorageGroup study) {
        if (!study.hasChild("samples")) return List.of();
        List<Sample> out = new ArrayList<>();
        try (var samplesGroup = study.openGroup("samples")) {
            for (String name : samplesGroup.childNames()) {
                try (var row = samplesGroup.openGroup(name)) {
                    String sampleId = readStringAttrOrDefault(
                        row, "sample_id", name);
                    String subjectExternalId = readStringAttrOrDefault(
                        row, "subject_external_id", "");
                    String sampleKind = readStringAttrOrDefault(
                        row, "sample_kind", "");
                    long collectedAt = readLongAttrOrDefault(
                        row, "collected_at", 0L);
                    Map<String, String> attrs = row.hasAttribute("attributes_json")
                        ? MiniJson.parseStringMap(
                            readStringAttrOrDefault(row, "attributes_json", "{}"))
                        : Map.of();
                    out.add(new Sample(sampleId, subjectExternalId,
                            sampleKind, collectedAt, attrs));
                }
            }
        }
        return out;
    }

    static String readStringAttrOrDefault(
            global.thalion.ttio.providers.StorageGroup g, String name,
            String fallback) {
        if (!g.hasAttribute(name)) return fallback;
        Object v = g.getAttribute(name);
        return v != null ? v.toString() : fallback;
    }

    static long readLongAttrOrDefault(
            global.thalion.ttio.providers.StorageGroup g, String name,
            long fallback) {
        if (!g.hasAttribute(name)) return fallback;
        Object v = g.getAttribute(name);
        if (v == null) return fallback;
        if (v instanceof Number n) return n.longValue();
        try {
            return Long.parseLong(v.toString());
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

}
