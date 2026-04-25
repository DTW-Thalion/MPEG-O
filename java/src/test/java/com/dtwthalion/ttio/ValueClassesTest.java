/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.ttio;

import com.dtwthalion.ttio.Enums.ChromatogramType;
import com.dtwthalion.ttio.Enums.Precision;
import com.dtwthalion.ttio.Enums.Compression;
import com.dtwthalion.ttio.Enums.ByteOrder;
import com.dtwthalion.ttio.Enums.SamplingMode;
import com.dtwthalion.ttio.Enums.AcquisitionMode;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class ValueClassesTest {

    @Test
    void precisionOrdinalsMatchObjC() {
        // ObjC TTIOPrecision: Float32=0, Float64=1, Int32=2, Int64=3,
        // UInt32=4, Complex128=5, UInt8=6 (M79). Java Precision.ordinal() must match.
        assertEquals(0, Precision.FLOAT32.ordinal());
        assertEquals(1, Precision.FLOAT64.ordinal());
        assertEquals(2, Precision.INT32.ordinal());
        assertEquals(3, Precision.INT64.ordinal());
        assertEquals(4, Precision.UINT32.ordinal());
        assertEquals(5, Precision.COMPLEX128.ordinal());
        assertEquals(6, Precision.UINT8.ordinal());
        assertEquals(7, Precision.values().length, "no stray extras");
    }

    @Test
    void compressionIncludesNumpressDelta() {
        assertEquals(3, Compression.NUMPRESS_DELTA.ordinal());
    }

    @Test
    void byteOrderOrdinalsMatchObjC() {
        assertEquals(0, ByteOrder.LITTLE_ENDIAN.ordinal());
        assertEquals(1, ByteOrder.BIG_ENDIAN.ordinal());
    }

    @Test
    void valueRangeSpanAndContains() {
        ValueRange r = new ValueRange(0.0, 10.0);
        assertEquals(10.0, r.span(), 1e-12);
        assertTrue(r.contains(5.0));
        assertFalse(r.contains(-1.0));
    }

    @Test
    void axisDescriptorFieldsNamedAfterObjC() {
        ValueRange range = new ValueRange(100.0, 1000.0);
        AxisDescriptor a = new AxisDescriptor(
            "mz", "m/z", range, Enums.SamplingMode.NON_UNIFORM);
        assertEquals("mz", a.name());
        assertEquals("m/z", a.unit());
        assertSame(range, a.valueRange());
        assertEquals(Enums.SamplingMode.NON_UNIFORM, a.samplingMode());
    }

    @Test
    void encodingSpecElementSize() {
        EncodingSpec f32 = new EncodingSpec(Enums.Precision.FLOAT32,
            Enums.Compression.ZLIB, Enums.ByteOrder.LITTLE_ENDIAN);
        EncodingSpec f64 = new EncodingSpec(Enums.Precision.FLOAT64,
            Enums.Compression.ZLIB, Enums.ByteOrder.LITTLE_ENDIAN);
        EncodingSpec c128 = new EncodingSpec(Enums.Precision.COMPLEX128,
            Enums.Compression.ZLIB, Enums.ByteOrder.LITTLE_ENDIAN);
        assertEquals(4, f32.elementSize());
        assertEquals(8, f64.elementSize());
        assertEquals(16, c128.elementSize());
    }

    @Test
    void cvParamShape() {
        CVParam p = new CVParam(
            "MS", "MS:1000515", "intensity array", "", "MS:1000131");
        assertEquals("MS", p.ontologyRef());
        assertEquals("MS:1000515", p.accession());
        assertEquals("intensity array", p.name());
        assertEquals("", p.value());
        assertEquals("MS:1000131", p.unit());
    }

    @Test
    void signalArrayIsCvAnnotatable() {
        SignalArray sa = SignalArray.ofDoubles(new double[]{1.0, 2.0, 3.0});
        assertTrue(sa instanceof com.dtwthalion.ttio.protocols.CVAnnotatable);
        CVParam p = new CVParam("MS", "MS:1000515", "intensity array", "", null);
        sa.addCvParam(p);
        assertEquals(java.util.List.of(p), sa.allCvParams());
        assertTrue(sa.hasCvParamWithAccession("MS:1000515"));
        assertEquals(java.util.List.of(p), sa.cvParamsForAccession("MS:1000515"));
        assertEquals(java.util.List.of(p), sa.cvParamsForOntologyRef("MS"));
        sa.removeCvParam(p);
        assertTrue(sa.allCvParams().isEmpty());
    }

    @Test
    void spectrumBaseHasAxesAndPrecursor() {
        SignalArray mz = SignalArray.ofDoubles(new double[]{100.0, 200.0});
        SignalArray intensity = SignalArray.ofDoubles(new double[]{1.0, 2.0});
        AxisDescriptor mzAxis = new AxisDescriptor("mz", "m/z", null, Enums.SamplingMode.NON_UNIFORM);
        Spectrum s = new Spectrum(
            java.util.Map.of("mz", mz, "intensity", intensity),
            java.util.List.of(mzAxis),
            3, 45.2, 500.0, 2);
        assertEquals(3, s.indexPosition());
        assertEquals(45.2, s.scanTimeSeconds(), 1e-9);
        assertEquals(500.0, s.precursorMz(), 1e-9);
        assertEquals(2, s.precursorCharge());
        assertSame(mzAxis, s.axes().get(0));
    }

    @Test
    void massSpectrumTypedAccessors() {
        double[] mz = {100.0, 200.0};
        double[] intensity = {1.0, 2.0};
        MassSpectrum ms = new MassSpectrum(mz, intensity,
            0, 10.0,  // indexPosition, scanTimeSeconds
            500.0, 2,  // precursorMz, precursorCharge (on base)
            2, Enums.Polarity.POSITIVE, new ValueRange(50.0, 2000.0));
        assertEquals(2, ms.msLevel());
        assertEquals(Enums.Polarity.POSITIVE, ms.polarity());
        assertEquals(new ValueRange(50.0, 2000.0), ms.scanWindow());
        assertEquals(500.0, ms.precursorMz(), 1e-9);
        assertNotNull(ms.mzArray());
        assertNotNull(ms.intensityArray());
        assertEquals(mz.length, ms.mzArray().length());
    }

    @Test
    void numpressScaleForRangeMatchesObjC() {
        // TTIONumpress +scaleForValueRangeMin:max: takes (min, max) explicitly.
        long s = NumpressCodec.scaleForRange(0.0, 1000.0);
        assertTrue(s > 0);
        // When called via computeScale on [0, 1000], the result must agree.
        long s2 = NumpressCodec.computeScale(new double[]{0.0, 1000.0});
        assertEquals(s, s2);
    }

    @Test
    void nmrSpectrumTypedAccessors() {
        double[] cs = {1.0, 2.0, 3.0};
        double[] intensity = {0.1, 0.2, 0.3};
        NMRSpectrum nmr = new NMRSpectrum(cs, intensity,
            0, 0.0, "1H", 400.0);
        assertEquals("1H", nmr.nucleusType());
        assertEquals(400.0, nmr.spectrometerFrequencyMHz(), 1e-9);
        assertNotNull(nmr.chemicalShiftArray());
        assertEquals(cs.length, nmr.chemicalShiftArray().length());
    }

    @Test
    void nmr2DSpectrumExtendsSpectrum() {
        AxisDescriptor f1 = new AxisDescriptor("1H", "ppm",
            new ValueRange(0.0, 10.0), Enums.SamplingMode.UNIFORM);
        AxisDescriptor f2 = new AxisDescriptor("13C", "ppm",
            new ValueRange(0.0, 200.0), Enums.SamplingMode.UNIFORM);
        NMR2DSpectrum spec = new NMR2DSpectrum(new double[200], 20, 10, f1, f2,
            "1H", "13C");
        assertTrue(spec instanceof Spectrum);
        assertEquals(20, spec.width());
        assertEquals(10, spec.height());
    }

    @Test
    void fidExtendsSignalArray() {
        double[] complexData = new double[1024];  // 512 complex pairs
        FreeInductionDecay fid = new FreeInductionDecay(
            complexData, 512, 5e-5, 100.0);
        assertTrue(fid instanceof SignalArray);
        assertEquals(512, fid.scanCount());
        assertEquals(5e-5, fid.dwellTimeSeconds(), 1e-12);
        assertEquals(100.0, fid.receiverGain(), 1e-9);
    }

    @Test
    void chromatogramExtendsSpectrum() {
        double[] time = {0.0, 1.0, 2.0};
        double[] intensity = {100.0, 200.0, 300.0};
        Chromatogram chrom = new Chromatogram(time, intensity,
            ChromatogramType.TIC, 0, 0, 0);
        assertTrue(chrom instanceof Spectrum);
        assertNotNull(chrom.timeArray());
        assertEquals(ChromatogramType.TIC, chrom.type());
    }

    @Test
    void spectrumIndexElementAccessors() {
        SpectrumIndex idx = new SpectrumIndex(3,
            new long[]{0, 10, 20},
            new int[]{10, 10, 10},
            new double[]{1.0, 2.0, 3.0},
            new int[]{1, 2, 1},
            new int[]{1, 1, -1},
            new double[]{0.0, 500.0, 0.0},
            new int[]{0, 2, 0},
            new double[]{100.0, 200.0, 300.0}
        );
        assertEquals(10, idx.offsetAt(1));
        assertEquals(10, idx.lengthAt(2));
        assertEquals(1.0, idx.retentionTimeAt(0), 1e-12);
        assertEquals(2, idx.msLevelAt(1));
        assertEquals(Enums.Polarity.NEGATIVE, idx.polarityAt(2));
        assertEquals(500.0, idx.precursorMzAt(1), 1e-9);
        assertEquals(2, idx.precursorChargeAt(1));
        assertEquals(300.0, idx.basePeakIntensityAt(2), 1e-9);

        java.util.List<Integer> rtMatches =
            idx.indicesInRetentionTimeRange(new ValueRange(1.5, 2.5));
        assertEquals(java.util.List.of(1), rtMatches);

        java.util.List<Integer> msLevel1 = idx.indicesForMsLevel(1);
        assertEquals(java.util.List.of(0, 2), msLevel1);
    }

    @Test
    void acquisitionRunImplementsProtocols() throws Exception {
        SpectrumIndex idx = new SpectrumIndex(2,
            new long[]{0, 2}, new int[]{2, 2},
            new double[]{0.0, 1.0}, new int[]{1, 1},
            new int[]{1, 1}, new double[]{0.0, 0.0},
            new int[]{0, 0}, new double[]{10.0, 20.0}
        );
        java.util.Map<String, double[]> channels = java.util.Map.of(
            "mz", new double[]{100.0, 200.0, 100.0, 200.0},
            "intensity", new double[]{1.0, 2.0, 3.0, 4.0}
        );
        AcquisitionRun run = new AcquisitionRun("run0",
            Enums.AcquisitionMode.MS1_DDA, idx, null, channels,
            java.util.List.of(), java.util.List.of(), null, 0);

        assertTrue(run instanceof com.dtwthalion.ttio.protocols.Indexable);
        assertEquals(2, run.count());
        assertNotNull(run.objectAtIndex(0));

        assertTrue(run instanceof com.dtwthalion.ttio.protocols.Streamable);
        assertTrue(run.hasMore());
        Spectrum s0 = run.nextObject();
        assertNotNull(s0);
        assertEquals(1, run.currentPosition());
        run.reset();
        assertEquals(0, run.currentPosition());

        assertTrue(run instanceof com.dtwthalion.ttio.protocols.Provenanceable);
        assertEquals(java.util.List.of(), run.provenanceChain());
        assertEquals(java.util.List.of(), run.inputEntities());
    }

    @Test
    void msImageHasDatasetLevelFields() {
        double[] cube = new double[12]; // 2x2x3
        MSImage img = new MSImage(2, 2, 3, 64, 10.0, 10.0, "raster", cube,
            "imaging run", "ISA-001",
            java.util.List.of(), java.util.List.of(), java.util.List.of());
        assertEquals("imaging run", img.title());
        assertEquals("ISA-001", img.isaInvestigationId());
        assertEquals(64, img.tileSize());
        assertTrue(img.identifications().isEmpty());
        assertTrue(img.quantifications().isEmpty());
        assertTrue(img.provenanceRecords().isEmpty());
    }

    @Test
    void identificationTypedEvidenceChain() {
        java.util.List<String> evidence = java.util.List.of("MS:1002217", "MS:1001143");
        Identification i = new Identification(
            "run_0001", 42, "CHEBI:17234", 0.95, evidence);
        assertEquals("run_0001", i.runName());
        assertEquals(42, i.spectrumIndex());
        assertEquals("CHEBI:17234", i.chemicalEntity());
        assertEquals(0.95, i.confidenceScore(), 1e-9);
        assertEquals(evidence, i.evidenceChain());
    }

    @Test
    void quantificationFields() {
        Quantification q = new Quantification(
            "CHEBI:17234", "sample1", 1234.5, "median");
        assertEquals("CHEBI:17234", q.chemicalEntity());
        assertEquals("sample1", q.sampleRef());
        assertEquals(1234.5, q.abundance(), 1e-9);
        assertEquals("median", q.normalizationMethod());
    }

    @Test
    void provenanceRecordContainsInputRef() {
        ProvenanceRecord r = new ProvenanceRecord(
            1700000000L, "MSConvert 3.0",
            java.util.Map.of("threshold", "100"),
            java.util.List.of("file:///data/raw/run.mzML"),
            java.util.List.of("file:///data/processed/run.tio"));
        assertTrue(r.containsInputRef("file:///data/raw/run.mzML"));
        assertFalse(r.containsInputRef("file:///data/raw/other.mzML"));
    }

    @Test
    void transitionListCountAndIndex() {
        TransitionList.Transition t = new TransitionList.Transition(
            500.0, 100.0, 25.0, new ValueRange(10.0, 20.0));
        TransitionList tl = new TransitionList(java.util.List.of(t));
        assertEquals(1, tl.count());
        assertSame(t, tl.transitionAtIndex(0));
        assertEquals(new ValueRange(10.0, 20.0),
                     tl.transitionAtIndex(0).retentionTimeWindow());
    }

    @Test
    void accessPolicyHoldsMap() {
        com.dtwthalion.ttio.protection.AccessPolicy p =
            new com.dtwthalion.ttio.protection.AccessPolicy(
                java.util.Map.of("subjects", java.util.List.of("alice"),
                                 "key_id", "kek-1"));
        assertEquals(java.util.List.of("alice"), p.policy().get("subjects"));
        assertEquals("kek-1", p.policy().get("key_id"));

        com.dtwthalion.ttio.protection.AccessPolicy empty =
            new com.dtwthalion.ttio.protection.AccessPolicy(null);
        assertTrue(empty.policy().isEmpty());
    }

    @Test
    void verifierStatusWrapping() {
        byte[] data = "hello, mpeg-o".getBytes(java.nio.charset.StandardCharsets.UTF_8);
        byte[] key = new byte[32];
        java.util.Arrays.fill(key, (byte) '0');

        // NOT_SIGNED
        assertEquals(com.dtwthalion.ttio.protection.Verifier.Status.NOT_SIGNED,
            com.dtwthalion.ttio.protection.Verifier.verify(data, null, key));
        assertEquals(com.dtwthalion.ttio.protection.Verifier.Status.NOT_SIGNED,
            com.dtwthalion.ttio.protection.Verifier.verify(data, "", key));

        // VALID — sign with SignatureManager, then verify
        String sig = com.dtwthalion.ttio.protection.SignatureManager.sign(data, key);
        assertEquals(com.dtwthalion.ttio.protection.Verifier.Status.VALID,
            com.dtwthalion.ttio.protection.Verifier.verify(data, sig, key));

        // INVALID — wrong key
        byte[] wrongKey = new byte[32];
        java.util.Arrays.fill(wrongKey, (byte) '1');
        assertEquals(com.dtwthalion.ttio.protection.Verifier.Status.INVALID,
            com.dtwthalion.ttio.protection.Verifier.verify(data, sig, wrongKey));
    }

    @Test
    void anonymizationPolicyDefaults() {
        com.dtwthalion.ttio.protection.Anonymizer.AnonymizationPolicy p =
            com.dtwthalion.ttio.protection.Anonymizer.AnonymizationPolicy.defaults();
        assertTrue(p.redactSaavSpectra());
        assertEquals(0.0, p.maskIntensityBelowQuantile(), 1e-9);
        assertEquals(-1, p.coarsenMzDecimals());
    }

    @Test
    void encryptionRoundTrip() {
        byte[] key = new byte[32];
        java.util.Arrays.fill(key, (byte) '0');
        byte[] plaintext = "hello, mpeg-o encryption".getBytes(
            java.nio.charset.StandardCharsets.UTF_8);

        com.dtwthalion.ttio.protection.EncryptionManager.EncryptResult r =
            com.dtwthalion.ttio.protection.EncryptionManager.encrypt(plaintext, key);
        // decrypt(ciphertext, iv, tag, key)
        byte[] recovered = com.dtwthalion.ttio.protection.EncryptionManager.decrypt(
            r.ciphertext(), r.iv(), r.tag(), key);
        assertArrayEquals(plaintext, recovered);
    }

    @Test
    void keyRotationManagerRoundTrip() {
        com.dtwthalion.ttio.protection.KeyRotationManager mgr =
            new com.dtwthalion.ttio.protection.KeyRotationManager();
        byte[] kek = new byte[32];
        java.util.Arrays.fill(kek, (byte) 'K');
        mgr.enableEnvelopeEncryption(kek, "kek-1");
        assertNotNull(mgr.getDek());
        assertEquals(32, mgr.getDek().length);
    }

    @Test
    void signatureRoundTrip() {
        byte[] data = "hello, mpeg-o signatures".getBytes(
            java.nio.charset.StandardCharsets.UTF_8);
        byte[] key = new byte[32];
        java.util.Arrays.fill(key, (byte) '0');

        String sig = com.dtwthalion.ttio.protection.SignatureManager.sign(data, key);
        assertTrue(com.dtwthalion.ttio.protection.SignatureManager.verify(data, sig, key));

        byte[] wrongKey = new byte[32];
        java.util.Arrays.fill(wrongKey, (byte) '1');
        assertFalse(com.dtwthalion.ttio.protection.SignatureManager.verify(data, sig, wrongKey));
    }

    @Test
    void acquisitionRunHasEncryptableSurface() {
        SpectrumIndex idx = new SpectrumIndex(0,
            new long[0], new int[0], new double[0], new int[0], new int[0],
            new double[0], new int[0], new double[0]);
        AcquisitionRun run = new AcquisitionRun("run0",
            Enums.AcquisitionMode.MS1_DDA, idx, null, java.util.Map.of(),
            java.util.List.of(), java.util.List.of(), null, 0);
        assertTrue(run instanceof com.dtwthalion.ttio.protocols.Encryptable);
        assertNull(run.accessPolicy());
        com.dtwthalion.ttio.protection.AccessPolicy pol =
            new com.dtwthalion.ttio.protection.AccessPolicy(
                java.util.Map.of("owner", "alice"));
        run.setAccessPolicy(pol);
        assertSame(pol, run.accessPolicy());
    }

    @Test
    void spectralDatasetHasEncryptableSurface() {
        // SpectralDataset construction is complex (opens an HDF5 file).
        // Use class-level surface check.
        java.util.Set<String> names = java.util.Arrays.stream(
            SpectralDataset.class.getMethods())
            .map(java.lang.reflect.Method::getName)
            .collect(java.util.stream.Collectors.toSet());
        assertTrue(names.contains("encryptWithKey"));
        assertTrue(names.contains("decryptWithKey"));
        assertTrue(names.contains("accessPolicy"));
        assertTrue(names.contains("setAccessPolicy"));
        assertTrue(com.dtwthalion.ttio.protocols.Encryptable.class
            .isAssignableFrom(SpectralDataset.class));
    }

    @Test
    void queryBuilderIntersects() {
        SpectrumIndex idx = new SpectrumIndex(4,
            new long[]{0, 10, 20, 30},
            new int[]{10, 10, 10, 10},
            new double[]{1.0, 2.0, 3.0, 4.0},
            new int[]{1, 2, 2, 1},
            new int[]{1, 1, -1, 1},
            new double[]{0.0, 500.0, 510.0, 0.0},
            new int[]{0, 2, 2, 0},
            new double[]{100.0, 200.0, 300.0, 400.0});
        java.util.List<Integer> matches = Query.onIndex(idx)
            .withMsLevel(2)
            .withRetentionTimeRange(new ValueRange(1.5, 2.5))
            .matchingIndices();
        assertEquals(java.util.List.of(1), matches);

        matches = Query.onIndex(idx)
            .withPolarity(Enums.Polarity.NEGATIVE)
            .matchingIndices();
        assertEquals(java.util.List.of(2), matches);
    }

    @Test
    void streamReaderExistsAndIsAutoCloseable() {
        // Full round-trip requires a written .tio file; surface-check
        // for class existence and AutoCloseable contract is the slice's
        // parity deliverable. The underlying AcquisitionRun.readFrom is
        // already exercised by SpectralDatasetTest cross-compat checks.
        Class<?> c = StreamReader.class;
        assertTrue(java.util.Arrays.stream(c.getMethods())
            .anyMatch(m -> m.getName().equals("nextSpectrum")));
        assertTrue(java.util.Arrays.stream(c.getMethods())
            .anyMatch(m -> m.getName().equals("totalCount")));
        assertTrue(AutoCloseable.class.isAssignableFrom(c));
    }

    @Test
    void streamWriterBuffersSpectra() {
        StreamWriter w = new StreamWriter(
            "/tmp/does-not-matter-not-flushed.tio", "run0",
            Enums.AcquisitionMode.MS1_DDA,
            new InstrumentConfig("", "", "", "", "", ""));
        assertEquals(0, w.spectrumCount());

        double[] mz = {100.0, 200.0};
        double[] intensity = {1.0, 2.0};
        MassSpectrum ms = new MassSpectrum(mz, intensity,
            0, 0.0, 0.0, 0, 1, Enums.Polarity.UNKNOWN, null);
        w.appendSpectrum(ms);
        assertEquals(1, w.spectrumCount());

        w.close();
    }

    @Test
    void storageProtocolsExposed() {
        com.dtwthalion.ttio.providers.CompoundField cf =
            new com.dtwthalion.ttio.providers.CompoundField(
                "accession",
                com.dtwthalion.ttio.providers.CompoundField.Kind.VL_STRING);
        assertEquals("accession", cf.name());
        assertEquals(com.dtwthalion.ttio.providers.CompoundField.Kind.VL_STRING,
                     cf.kind());

        // Interface types are loadable and have the expected methods.
        assertTrue(com.dtwthalion.ttio.providers.StorageProvider.class.isInterface());
        assertTrue(com.dtwthalion.ttio.providers.StorageGroup.class.isInterface());
        assertTrue(com.dtwthalion.ttio.providers.StorageDataset.class.isInterface());

        // CompoundField.Kind: 4 v0.x primitives + VL_BYTES added in v1.0.
        assertEquals(5, com.dtwthalion.ttio.providers.CompoundField.Kind.values().length);
    }

    @Test
    void memoryProviderInstantiates() {
        com.dtwthalion.ttio.providers.MemoryProvider p =
            new com.dtwthalion.ttio.providers.MemoryProvider();
        assertNotNull(p);
        assertEquals("memory", p.providerName());
        // Instance satisfies the StorageProvider interface contract.
        assertTrue(p instanceof com.dtwthalion.ttio.providers.StorageProvider);
    }

    @Test
    void providerRegistryResolvesMemoryByName() {
        // ProviderRegistry.discover() returns a name→class map; open()
        // with an explicit provider name is the name-based lookup.
        java.util.Map<String, Class<? extends com.dtwthalion.ttio.providers.StorageProvider>>
            providers = com.dtwthalion.ttio.providers.ProviderRegistry.discover();
        assertTrue(providers.containsKey("memory"),
                "expected memory in " + providers.keySet());

        String url = "memory://value-classes-parity-" + System.nanoTime();
        try (com.dtwthalion.ttio.providers.StorageProvider p =
                com.dtwthalion.ttio.providers.ProviderRegistry.open(
                    url,
                    com.dtwthalion.ttio.providers.StorageProvider.Mode.CREATE,
                    "memory")) {
            assertNotNull(p);
            assertEquals("memory", p.providerName());
        }
        com.dtwthalion.ttio.providers.MemoryProvider.discardStore(url);
    }

    // ── M41.8 Task 1: Import/Export subsystem xref parity tests ──────────────

    @Test
    void cvTermMapperBasicAccessions() {
        // PSI-MS accessions MS:1000521 = Float32, MS:1000523 = Float64.
        assertEquals(Enums.Precision.FLOAT64,
            com.dtwthalion.ttio.importers.CVTermMapper.precisionFor("MS:1000523"));
        assertEquals(Enums.Precision.FLOAT32,
            com.dtwthalion.ttio.importers.CVTermMapper.precisionFor("MS:1000521"));
        // Unknown accession → FLOAT64 default (matches ObjC and Python).
        assertEquals(Enums.Precision.FLOAT64,
            com.dtwthalion.ttio.importers.CVTermMapper.precisionFor("MS:9999999"),
            "unknown accession should return FLOAT64 default");
        // Callers that need to distinguish unknown from FLOAT64 use isPrecisionAccession.
        assertTrue(com.dtwthalion.ttio.importers.CVTermMapper.isPrecisionAccession("MS:1000523"));
        assertFalse(com.dtwthalion.ttio.importers.CVTermMapper.isPrecisionAccession("MS:9999999"));
    }

    @Test
    void streamWriterFlushRoundTrip(@org.junit.jupiter.api.io.TempDir java.nio.file.Path tmp) throws Exception {
        String path = tmp.resolve("streamed.tio").toString();
        StreamWriter w = new StreamWriter(path, "run_0001",
            Enums.AcquisitionMode.MS1_DDA,
            new InstrumentConfig("", "", "", "", "", ""));

        for (int i = 0; i < 3; i++) {
            double[] mz = { 100.0 + i, 200.0 + i };
            double[] intensity = { 1.0 + i, 2.0 + i };
            MassSpectrum ms = new MassSpectrum(mz, intensity,
                i, (double) i, 0.0, 0, 1, Enums.Polarity.POSITIVE, null);
            w.appendSpectrum(ms);
        }

        assertEquals(3, w.spectrumCount());
        w.flush();

        try (SpectralDataset ds = SpectralDataset.open(path)) {
            AcquisitionRun run = ds.msRuns().get("run_0001");
            assertNotNull(run);
            assertEquals(3, run.count());
        }
    }

    @Test
    void activationMethodIntegerValuesMatchObjC() {
        // M74: values persist as int32 in spectrum_index; must match ObjC.
        assertEquals(0, Enums.ActivationMethod.NONE.intValue());
        assertEquals(1, Enums.ActivationMethod.CID.intValue());
        assertEquals(2, Enums.ActivationMethod.HCD.intValue());
        assertEquals(3, Enums.ActivationMethod.ETD.intValue());
        assertEquals(4, Enums.ActivationMethod.UVPD.intValue());
        assertEquals(5, Enums.ActivationMethod.ECD.intValue());
        assertEquals(6, Enums.ActivationMethod.EThcD.intValue());
    }

    @Test
    void activationMethodFromInt() {
        assertEquals(Enums.ActivationMethod.HCD, Enums.ActivationMethod.fromInt(2));
        assertEquals(Enums.ActivationMethod.EThcD, Enums.ActivationMethod.fromInt(6));
        // Unknown integer falls back to NONE (forward-compat).
        assertEquals(Enums.ActivationMethod.NONE, Enums.ActivationMethod.fromInt(99));
    }

    @Test
    void isolationWindowBoundsAndWidth() {
        IsolationWindow w = new IsolationWindow(500.0, 1.0, 2.0);
        assertEquals(500.0, w.targetMz(), 1e-12);
        assertEquals(1.0, w.lowerOffset(), 1e-12);
        assertEquals(2.0, w.upperOffset(), 1e-12);
        assertEquals(499.0, w.lowerBound(), 1e-12);
        assertEquals(502.0, w.upperBound(), 1e-12);
        assertEquals(3.0, w.width(), 1e-12);
    }

    @Test
    void isolationWindowEquality() {
        IsolationWindow a = new IsolationWindow(500.0, 0.5, 0.5);
        IsolationWindow b = new IsolationWindow(500.0, 0.5, 0.5);
        IsolationWindow c = new IsolationWindow(500.0, 0.5, 1.0);
        assertEquals(a, b);
        assertNotEquals(a, c);
        assertEquals(a.hashCode(), b.hashCode());
    }

    @Test
    void massSpectrumHasActivationAndIsolationFields() {
        double[] mz = { 100.0, 200.0 };
        double[] intensity = { 1.0, 2.0 };

        // Backward-compatible constructor defaults new fields.
        MassSpectrum ms1 = new MassSpectrum(mz, intensity,
            0, 0.0, 0.0, 0, 1, Enums.Polarity.POSITIVE, null);
        assertEquals(Enums.ActivationMethod.NONE, ms1.activationMethod());
        assertNull(ms1.isolationWindow());

        // Full constructor populates both.
        IsolationWindow iw = new IsolationWindow(500.0, 1.0, 1.0);
        MassSpectrum ms2 = new MassSpectrum(mz, intensity,
            1, 1.5, 500.0, 2, 2, Enums.Polarity.POSITIVE, null,
            Enums.ActivationMethod.HCD, iw);
        assertEquals(Enums.ActivationMethod.HCD, ms2.activationMethod());
        assertSame(iw, ms2.isolationWindow());
        assertEquals(500.0, ms2.isolationWindow().targetMz(), 1e-12);
    }
}
