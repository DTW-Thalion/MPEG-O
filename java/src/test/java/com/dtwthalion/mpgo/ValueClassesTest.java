/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

import com.dtwthalion.mpgo.Enums.ChromatogramType;
import com.dtwthalion.mpgo.Enums.Precision;
import com.dtwthalion.mpgo.Enums.Compression;
import com.dtwthalion.mpgo.Enums.ByteOrder;
import com.dtwthalion.mpgo.Enums.SamplingMode;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class ValueClassesTest {

    @Test
    void precisionOrdinalsMatchObjC() {
        // ObjC MPGOPrecision: Float32=0, Float64=1, Int32=2, Int64=3,
        // UInt32=4, Complex128=5. Java Precision.ordinal() must match.
        assertEquals(0, Precision.FLOAT32.ordinal());
        assertEquals(1, Precision.FLOAT64.ordinal());
        assertEquals(2, Precision.INT32.ordinal());
        assertEquals(3, Precision.INT64.ordinal());
        assertEquals(4, Precision.UINT32.ordinal());
        assertEquals(5, Precision.COMPLEX128.ordinal());
        assertEquals(6, Precision.values().length, "no stray extras");
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
        assertTrue(sa instanceof com.dtwthalion.mpgo.protocols.CVAnnotatable);
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
        // MPGONumpress +scaleForValueRangeMin:max: takes (min, max) explicitly.
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

        assertTrue(run instanceof com.dtwthalion.mpgo.protocols.Indexable);
        assertEquals(2, run.count());
        assertNotNull(run.objectAtIndex(0));

        assertTrue(run instanceof com.dtwthalion.mpgo.protocols.Streamable);
        assertTrue(run.hasMore());
        Spectrum s0 = run.nextObject();
        assertNotNull(s0);
        assertEquals(1, run.currentPosition());
        run.reset();
        assertEquals(0, run.currentPosition());

        assertTrue(run instanceof com.dtwthalion.mpgo.protocols.Provenanceable);
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
            java.util.List.of("file:///data/processed/run.mpgo"));
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
}
