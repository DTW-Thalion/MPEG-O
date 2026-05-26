package global.thalion.ttio.transport;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.IRImage;
import global.thalion.ttio.Identification;
import global.thalion.ttio.MSImage;
import global.thalion.ttio.MassSpectrum;
import global.thalion.ttio.ProvenanceRecord;
import global.thalion.ttio.Quantification;
import global.thalion.ttio.RamanImage;
import global.thalion.ttio.SpectralDataset;
import global.thalion.ttio.Spectrum;
import global.thalion.ttio.genomics.GenomicRun;
import global.thalion.ttio.genomics.ReferenceImport;

import java.io.OutputStream;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/** Enumerates every first-class accessor on {@link SpectralDataset}
 *  that is covered by v0.11's transport-spec round-trip. Each entry
 *  builds an isolated fixture and supplies a content-equality assertion
 *  scoped to that one accessor.
 *
 *  <p>Stage 1 (Task 1.10): REFERENCES, MS_RUNS, GENOMIC_RUNS, IMAGE,
 *  IDENTIFICATIONS, QUANTIFICATIONS, DATASET_PROVENANCE,
 *  ENCRYPTION_ALGORITHM. SUBJECTS + SAMPLES are deferred until they
 *  exist as first-class entities on {@link SpectralDataset}; the v0.11
 *  spec mentions them but the data model still surfaces them only as
 *  server-side cohort predicates.</p>
 *
 *  <p>Stage 5 (Task 5.6, Deferral 1): MS_IMAGE_PROCESSED, RAMAN_IMAGE,
 *  IR_IMAGE. The MS_IMAGE_PROCESSED entry shares the MSImage fixture
 *  with {@link #IMAGE} but overrides the encode step to call
 *  {@code writeImageProcessed} (opt-in sparse wire mode) instead of
 *  {@code writeImage} so the conformance suite exercises both wire
 *  shapes. RAMAN_IMAGE / IR_IMAGE use {@code writeDataset} unchanged
 *  because they integrate via the §5.4.5 prelude image block.</p> */
public enum AccessorSpec {

    REFERENCES {
        @Override public Path buildFixture(Path tmp) throws Exception {
            return FixtureBuilder.buildReferenceOnly(tmp.resolve("ref.tio"));
        }

        @Override public void assertContentEquals(SpectralDataset a, SpectralDataset b) {
            if (a.references().size() != b.references().size()) {
                throw new AssertionError("reference count mismatch: "
                    + a.references().size() + " vs " + b.references().size());
            }
            a.references().forEach((uri, refA) -> {
                ReferenceImport refB = b.references().get(uri);
                if (refB == null) {
                    throw new AssertionError(
                        "missing reference " + uri + " in round-trip output");
                }
                // Per-chromosome name + sequence comparison.
                if (refA.chromosomes().size() != refB.chromosomes().size()) {
                    throw new AssertionError("chromosome count mismatch for "
                        + uri + ": " + refA.chromosomes().size()
                        + " vs " + refB.chromosomes().size());
                }
                for (int i = 0; i < refA.chromosomes().size(); i++) {
                    String nameA = refA.chromosomes().get(i);
                    String nameB = refB.chromosomes().get(i);
                    if (!nameA.equals(nameB)) {
                        throw new AssertionError("chromosome name mismatch at "
                            + uri + "[" + i + "]: '" + nameA + "' vs '" + nameB + "'");
                    }
                    byte[] seqA = refA.sequences().get(i);
                    byte[] seqB = refB.sequences().get(i);
                    if (!Arrays.equals(seqA, seqB)) {
                        throw new AssertionError("chromosome sequence mismatch at "
                            + uri + "[" + i + "] '" + nameA + "'");
                    }
                }
            });
        }
    },

    MS_RUNS {
        @Override public Path buildFixture(Path tmp) throws Exception {
            return FixtureBuilder.buildMsRunsOnly(tmp.resolve("ms_runs.tio"));
        }

        @Override public void assertContentEquals(SpectralDataset a, SpectralDataset b) {
            Map<String, AcquisitionRun> ma = a.msRuns();
            Map<String, AcquisitionRun> mb = b.msRuns();
            if (!ma.keySet().equals(mb.keySet())) {
                throw new AssertionError("ms-run name set mismatch: "
                    + ma.keySet() + " vs " + mb.keySet());
            }
            for (String name : ma.keySet()) {
                AcquisitionRun ra = ma.get(name);
                AcquisitionRun rb = mb.get(name);
                if (ra.spectrumCount() != rb.spectrumCount()) {
                    throw new AssertionError("spectrum count mismatch for run "
                        + name + ": " + ra.spectrumCount() + " vs "
                        + rb.spectrumCount());
                }
                for (int i = 0; i < ra.spectrumCount(); i++) {
                    Spectrum sa = ra.objectAtIndex(i);
                    Spectrum sb = rb.objectAtIndex(i);
                    if (Math.abs(sa.scanTimeSeconds() - sb.scanTimeSeconds()) > 1e-12) {
                        throw new AssertionError("scanTime mismatch at "
                            + name + "/" + i);
                    }
                    if (Math.abs(sa.precursorMz() - sb.precursorMz()) > 1e-12) {
                        throw new AssertionError("precursorMz mismatch at "
                            + name + "/" + i);
                    }
                    if (sa instanceof MassSpectrum maSp
                            && sb instanceof MassSpectrum mbSp) {
                        if (!Arrays.equals(maSp.mzValues(), mbSp.mzValues())) {
                            throw new AssertionError("mz mismatch at "
                                + name + "/" + i);
                        }
                        if (!Arrays.equals(maSp.intensityValues(),
                                            mbSp.intensityValues())) {
                            throw new AssertionError("intensity mismatch at "
                                + name + "/" + i);
                        }
                    }
                }
            }
        }
    },

    GENOMIC_RUNS {
        @Override public Path buildFixture(Path tmp) throws Exception {
            return FixtureBuilder.buildGenomicRunsOnly(tmp.resolve("genomic.tio"));
        }

        @Override public void assertContentEquals(SpectralDataset a, SpectralDataset b) {
            Map<String, GenomicRun> ga = a.genomicRuns();
            Map<String, GenomicRun> gb = b.genomicRuns();
            if (!ga.keySet().equals(gb.keySet())) {
                throw new AssertionError("genomic-run name set mismatch: "
                    + ga.keySet() + " vs " + gb.keySet());
            }
            for (String name : ga.keySet()) {
                GenomicRun ra = ga.get(name);
                GenomicRun rb = gb.get(name);
                if (ra.readCount() != rb.readCount()) {
                    throw new AssertionError("read count mismatch for run "
                        + name + ": " + ra.readCount() + " vs "
                        + rb.readCount());
                }
                if (!Objects.equals(ra.referenceUri(), rb.referenceUri())) {
                    throw new AssertionError("referenceUri mismatch for run "
                        + name + ": '" + ra.referenceUri() + "' vs '"
                        + rb.referenceUri() + "'");
                }
                if (!Objects.equals(ra.platform(), rb.platform())) {
                    throw new AssertionError("platform mismatch for run "
                        + name);
                }
                if (!Objects.equals(ra.sampleName(), rb.sampleName())) {
                    throw new AssertionError("sampleName mismatch for run "
                        + name);
                }
                if (ra.acquisitionMode() != rb.acquisitionMode()) {
                    throw new AssertionError("acquisitionMode mismatch for run "
                        + name + ": " + ra.acquisitionMode() + " vs "
                        + rb.acquisitionMode());
                }
            }
        }
    },

    IMAGE {
        @Override public Path buildFixture(Path tmp) throws Exception {
            return FixtureBuilder.buildImageMsContinuous(tmp.resolve("image.tio"));
        }

        @Override public void assertContentEquals(SpectralDataset a, SpectralDataset b) {
            MSImage ia = a.image();
            MSImage ib = b.image();
            if (ia == null || ib == null) {
                throw new AssertionError("MSImage missing on at least one side: "
                    + "a=" + ia + ", b=" + ib);
            }
            if (ia.width() != ib.width()
                    || ia.height() != ib.height()
                    || ia.spectralPoints() != ib.spectralPoints()) {
                throw new AssertionError("image shape mismatch: "
                    + ia.width() + "x" + ia.height() + "x" + ia.spectralPoints()
                    + " vs " + ib.width() + "x" + ib.height()
                    + "x" + ib.spectralPoints());
            }
            double[] mzA = ia.mzAxis();
            double[] mzB = ib.mzAxis();
            if (mzA.length != mzB.length) {
                throw new AssertionError("mz-axis length mismatch: "
                    + mzA.length + " vs " + mzB.length);
            }
            for (int i = 0; i < mzA.length; i++) {
                if (Math.abs(mzA[i] - mzB[i]) >= 1e-9) {
                    throw new AssertionError("mz-axis[" + i + "] mismatch: "
                        + mzA[i] + " vs " + mzB[i]);
                }
            }
            double[] cubeA = ia.intensityCube();
            double[] cubeB = ib.intensityCube();
            if (cubeA.length != cubeB.length) {
                throw new AssertionError("intensity-cube length mismatch: "
                    + cubeA.length + " vs " + cubeB.length);
            }
            for (int i = 0; i < cubeA.length; i++) {
                if (Math.abs(cubeA[i] - cubeB[i]) >= 1e-9) {
                    throw new AssertionError("intensity-cube[" + i
                        + "] mismatch: " + cubeA[i] + " vs " + cubeB[i]);
                }
            }
        }
    },

    IDENTIFICATIONS {
        @Override public Path buildFixture(Path tmp) throws Exception {
            return FixtureBuilder.buildIdentificationsOnly(tmp.resolve("ids.tio"));
        }

        @Override public void assertContentEquals(SpectralDataset a, SpectralDataset b) {
            List<Identification> la = a.identifications();
            List<Identification> lb = b.identifications();
            if (la.size() != lb.size()) {
                throw new AssertionError("identification count mismatch: "
                    + la.size() + " vs " + lb.size());
            }
            for (int i = 0; i < la.size(); i++) {
                Identification ia = la.get(i);
                Identification ib = lb.get(i);
                if (!Objects.equals(ia.runName(), ib.runName())
                        || ia.spectrumIndex() != ib.spectrumIndex()
                        || !Objects.equals(ia.chemicalEntity(), ib.chemicalEntity())
                        || Math.abs(ia.confidenceScore() - ib.confidenceScore()) >= 1e-9
                        || !Objects.equals(ia.evidenceChain(), ib.evidenceChain())) {
                    throw new AssertionError("identification[" + i
                        + "] mismatch: " + ia + " vs " + ib);
                }
            }
        }
    },

    QUANTIFICATIONS {
        @Override public Path buildFixture(Path tmp) throws Exception {
            return FixtureBuilder.buildQuantificationsOnly(tmp.resolve("quants.tio"));
        }

        @Override public void assertContentEquals(SpectralDataset a, SpectralDataset b) {
            List<Quantification> la = a.quantifications();
            List<Quantification> lb = b.quantifications();
            if (la.size() != lb.size()) {
                throw new AssertionError("quantification count mismatch: "
                    + la.size() + " vs " + lb.size());
            }
            for (int i = 0; i < la.size(); i++) {
                Quantification qa = la.get(i);
                Quantification qb = lb.get(i);
                if (!Objects.equals(qa.chemicalEntity(), qb.chemicalEntity())
                        || !Objects.equals(qa.sampleRef(), qb.sampleRef())
                        || Math.abs(qa.abundance() - qb.abundance()) >= 1e-9
                        || !Objects.equals(qa.normalizationMethod(),
                                            qb.normalizationMethod())
                        || !Objects.equals(qa.unit(), qb.unit())) {
                    throw new AssertionError("quantification[" + i
                        + "] mismatch: " + qa + " vs " + qb);
                }
            }
        }
    },

    DATASET_PROVENANCE {
        @Override public Path buildFixture(Path tmp) throws Exception {
            return FixtureBuilder.buildDatasetProvenanceOnly(
                tmp.resolve("provenance.tio"));
        }

        @Override public void assertContentEquals(SpectralDataset a, SpectralDataset b) {
            List<ProvenanceRecord> la = a.provenanceRecords();
            List<ProvenanceRecord> lb = b.provenanceRecords();
            if (la.size() != lb.size()) {
                throw new AssertionError("provenance count mismatch: "
                    + la.size() + " vs " + lb.size());
            }
            for (int i = 0; i < la.size(); i++) {
                ProvenanceRecord pa = la.get(i);
                ProvenanceRecord pb = lb.get(i);
                if (pa.timestampUnix() != pb.timestampUnix()
                        || !Objects.equals(pa.software(), pb.software())
                        || !Objects.equals(pa.parameters(), pb.parameters())
                        || !Objects.equals(pa.inputRefs(), pb.inputRefs())
                        || !Objects.equals(pa.outputRefs(), pb.outputRefs())) {
                    throw new AssertionError("provenance record[" + i
                        + "] mismatch: " + pa + " vs " + pb);
                }
            }
        }
    },

    ENCRYPTION_ALGORITHM {
        @Override public Path buildFixture(Path tmp) throws Exception {
            return FixtureBuilder.buildEncryptionAlgorithmOnly(
                tmp.resolve("encrypted.tio"));
        }

        @Override public void assertContentEquals(SpectralDataset a, SpectralDataset b) {
            if (a.isEncrypted() != b.isEncrypted()) {
                throw new AssertionError("isEncrypted mismatch: "
                    + a.isEncrypted() + " vs " + b.isEncrypted());
            }
            if (!Objects.equals(a.encryptedAlgorithm(), b.encryptedAlgorithm())) {
                throw new AssertionError("encryptedAlgorithm mismatch: '"
                    + a.encryptedAlgorithm() + "' vs '"
                    + b.encryptedAlgorithm() + "'");
            }
        }
    },

    /** Stage 5 (Task 5.6): same MSImage fixture as {@link #IMAGE} but
     *  encoded via {@link TransportWriter#writeImageProcessed} (opt-in
     *  sparse wire mode). The decoded .tio carries an MSImage whose
     *  dense intensityCube round-trips byte-for-byte regardless of
     *  which wire mode was used. */
    MS_IMAGE_PROCESSED {
        @Override public Path buildFixture(Path tmp) throws Exception {
            return FixtureBuilder.buildImageMsProcessedOnly(
                tmp.resolve("image_processed.tio"));
        }

        @Override public void encode(SpectralDataset source, OutputStream out)
                throws Exception {
            // §5.4 prelude mimic, swapping writeImage→writeImageProcessed
            // for the MS image block. The fixture carries only an
            // MSImage (no other v0.11 content, no runs) so the rest of
            // the prelude collapses to a stream header + image +
            // EOS. Matches the {@code writeDataset} ordering exactly so
            // a downstream {@code materializeTo} reads a fully-formed
            // .tio with the dense cube restored.
            try (TransportWriter w = new TransportWriter(out)) {
                w.writeStreamHeader(
                    "1.2", source.title(), source.isaInvestigationId(),
                    List.of(PacketType.TRANSPORT_V0_11_FEATURE),
                    0);
                w.writeImageProcessed(source.image());
                w.writeEndOfStream();
            }
        }

        @Override public void assertContentEquals(SpectralDataset a, SpectralDataset b) {
            // Reuse the IMAGE comparator verbatim: processed mode is
            // strictly a wire-shape change, content equality is the
            // same predicate.
            AccessorSpec.IMAGE.assertContentEquals(a, b);
        }
    },

    /** Stage 5 (Task 5.6, Deferral 1): RAMAN_IMAGE round-trip via the
     *  v0.11 prelude image block (modality=1). Fixture is a small
     *  3x3x5 Raman cube; comparator asserts width/height/spectral-
     *  points/intensities/wavenumbers/excitation/laser-power/scan-
     *  pattern. */
    RAMAN_IMAGE {
        @Override public Path buildFixture(Path tmp) throws Exception {
            return FixtureBuilder.buildRamanImageOnly(
                tmp.resolve("raman.tio"));
        }

        @Override public void assertContentEquals(SpectralDataset a, SpectralDataset b) {
            RamanImage ra = a.ramanImage();
            RamanImage rb = b.ramanImage();
            if (ra == null || rb == null) {
                throw new AssertionError("RamanImage missing on at least "
                    + "one side: a=" + ra + ", b=" + rb);
            }
            if (ra.width() != rb.width()
                    || ra.height() != rb.height()
                    || ra.spectralPoints() != rb.spectralPoints()) {
                throw new AssertionError("raman shape mismatch: "
                    + ra.width() + "x" + ra.height() + "x" + ra.spectralPoints()
                    + " vs " + rb.width() + "x" + rb.height() + "x"
                    + rb.spectralPoints());
            }
            if (Math.abs(ra.excitationWavelengthNm()
                          - rb.excitationWavelengthNm()) >= 1e-9) {
                throw new AssertionError("excitationWavelengthNm mismatch: "
                    + ra.excitationWavelengthNm() + " vs "
                    + rb.excitationWavelengthNm());
            }
            if (Math.abs(ra.laserPowerMw() - rb.laserPowerMw()) >= 1e-9) {
                throw new AssertionError("laserPowerMw mismatch: "
                    + ra.laserPowerMw() + " vs " + rb.laserPowerMw());
            }
            if (!Objects.equals(ra.scanPattern(), rb.scanPattern())) {
                throw new AssertionError("raman scanPattern mismatch: '"
                    + ra.scanPattern() + "' vs '" + rb.scanPattern() + "'");
            }
            double[] wnA = ra.wavenumbers();
            double[] wnB = rb.wavenumbers();
            if (wnA.length != wnB.length) {
                throw new AssertionError("wavenumbers length mismatch: "
                    + wnA.length + " vs " + wnB.length);
            }
            for (int i = 0; i < wnA.length; i++) {
                if (Math.abs(wnA[i] - wnB[i]) >= 1e-9) {
                    throw new AssertionError("wavenumbers[" + i + "] mismatch: "
                        + wnA[i] + " vs " + wnB[i]);
                }
            }
            double[] cA = ra.intensityCube();
            double[] cB = rb.intensityCube();
            if (cA.length != cB.length) {
                throw new AssertionError("raman intensity-cube length: "
                    + cA.length + " vs " + cB.length);
            }
            for (int i = 0; i < cA.length; i++) {
                if (Math.abs(cA[i] - cB[i]) >= 1e-9) {
                    throw new AssertionError("raman intensity-cube[" + i
                        + "] mismatch: " + cA[i] + " vs " + cB[i]);
                }
            }
        }
    },

    /** Stage 5 (Task 5.6, Deferral 1): IR_IMAGE round-trip via the
     *  v0.11 prelude image block (modality=2). Fixture is a small
     *  3x3x5 IR cube; comparator asserts width/height/spectral-
     *  points/intensities/wavenumbers/mode/resolution/scan-pattern. */
    IR_IMAGE {
        @Override public Path buildFixture(Path tmp) throws Exception {
            return FixtureBuilder.buildIrImageOnly(
                tmp.resolve("ir.tio"));
        }

        @Override public void assertContentEquals(SpectralDataset a, SpectralDataset b) {
            IRImage ia = a.irImage();
            IRImage ib = b.irImage();
            if (ia == null || ib == null) {
                throw new AssertionError("IRImage missing on at least one "
                    + "side: a=" + ia + ", b=" + ib);
            }
            if (ia.width() != ib.width()
                    || ia.height() != ib.height()
                    || ia.spectralPoints() != ib.spectralPoints()) {
                throw new AssertionError("ir shape mismatch: "
                    + ia.width() + "x" + ia.height() + "x" + ia.spectralPoints()
                    + " vs " + ib.width() + "x" + ib.height() + "x"
                    + ib.spectralPoints());
            }
            if (ia.mode() != ib.mode()) {
                throw new AssertionError("ir mode mismatch: " + ia.mode()
                    + " vs " + ib.mode());
            }
            if (Math.abs(ia.resolutionCmInv() - ib.resolutionCmInv()) >= 1e-9) {
                throw new AssertionError("ir resolutionCmInv mismatch: "
                    + ia.resolutionCmInv() + " vs " + ib.resolutionCmInv());
            }
            if (!Objects.equals(ia.scanPattern(), ib.scanPattern())) {
                throw new AssertionError("ir scanPattern mismatch: '"
                    + ia.scanPattern() + "' vs '" + ib.scanPattern() + "'");
            }
            double[] wnA = ia.wavenumbers();
            double[] wnB = ib.wavenumbers();
            if (wnA.length != wnB.length) {
                throw new AssertionError("ir wavenumbers length mismatch: "
                    + wnA.length + " vs " + wnB.length);
            }
            for (int i = 0; i < wnA.length; i++) {
                if (Math.abs(wnA[i] - wnB[i]) >= 1e-9) {
                    throw new AssertionError("ir wavenumbers[" + i + "] mismatch: "
                        + wnA[i] + " vs " + wnB[i]);
                }
            }
            double[] cA = ia.intensityCube();
            double[] cB = ib.intensityCube();
            if (cA.length != cB.length) {
                throw new AssertionError("ir intensity-cube length: "
                    + cA.length + " vs " + cB.length);
            }
            for (int i = 0; i < cA.length; i++) {
                if (Math.abs(cA[i] - cB[i]) >= 1e-9) {
                    throw new AssertionError("ir intensity-cube[" + i
                        + "] mismatch: " + cA[i] + " vs " + cB[i]);
                }
            }
        }
    };

    public abstract Path buildFixture(Path tmp) throws Exception;
    public abstract void assertContentEquals(SpectralDataset a, SpectralDataset b);

    /** Stage 5 (Task 5.6): encode {@code source}'s .tio content to a
     *  .tis on {@code out}. Default uses {@link TransportWriter#writeDataset}
     *  so most accessors get the normal §5.4 prelude + dataset path.
     *  Override only when the accessor exercises a non-default wire
     *  shape (e.g. {@link #MS_IMAGE_PROCESSED} swaps to
     *  {@code writeImageProcessed}). */
    public void encode(SpectralDataset source, OutputStream out) throws Exception {
        try (TransportWriter w = new TransportWriter(out)) {
            w.writeDataset(source);
        }
    }
}
