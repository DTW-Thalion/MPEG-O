/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

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
}
