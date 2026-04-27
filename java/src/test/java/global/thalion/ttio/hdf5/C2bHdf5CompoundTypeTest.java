package global.thalion.ttio.hdf5;

import hdf.hdf5lib.HDF5Constants;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

/**
 * C2b — Hdf5CompoundType targeted coverage. The class was at 0%
 * coverage in V1 baseline (0/66 lines). These tests exercise every
 * public method through a single full lifecycle.
 *
 * <p>Per docs/coverage-workplan.md §C2 (C2.1 follow-up).</p>
 */
public class C2bHdf5CompoundTypeTest {

    @Test
    @DisplayName("C2b #1: construct + getTypeId + getTotalSize")
    void constructionAndGetters() {
        try (Hdf5CompoundType ct = new Hdf5CompoundType(32)) {
            assertEquals(32, ct.getTotalSize(),
                "getTotalSize should round-trip the constructor arg");
            assertTrue(ct.getTypeId() >= 0,
                "getTypeId should be non-negative for a fresh compound type");
        }
    }

    @Test
    @DisplayName("C2b #2: addField with native uint64 + close cleans up")
    void addNativeField() {
        try (Hdf5CompoundType ct = new Hdf5CompoundType(8)) {
            // H5T_NATIVE_UINT64 — a single 8-byte field.
            ct.addField("offset", HDF5Constants.H5T_NATIVE_UINT64, 0);
            assertTrue(ct.getTypeId() >= 0);
        }
    }

    @Test
    @DisplayName("C2b #3: addField with multiple primitives at offsets")
    void addMultipleFields() {
        // Layout: uint64 offset (0), uint32 length (8), float64 rt (16) — 24 bytes
        try (Hdf5CompoundType ct = new Hdf5CompoundType(24)) {
            ct.addField("offset", HDF5Constants.H5T_NATIVE_UINT64, 0);
            ct.addField("length", HDF5Constants.H5T_NATIVE_UINT32, 8);
            ct.addField("rt",     HDF5Constants.H5T_NATIVE_DOUBLE, 16);
        }
    }

    @Test
    @DisplayName("C2b #4: addVariableLengthStringField allocates aux type id")
    void addVariableLengthString() {
        try (Hdf5CompoundType ct = new Hdf5CompoundType(8)) {
            ct.addVariableLengthStringField("name", 0);
            // The VL string allocates an aux type id; close() releases.
            assertTrue(ct.getTypeId() >= 0);
        }
    }

    @Test
    @DisplayName("C2b #5: mixed primitive + VL string fields")
    void mixedFields() {
        // Layout: uint64 offset (0), VL string name (8) — 16 bytes (VL strings
        // are 8-byte pointers in compound types).
        try (Hdf5CompoundType ct = new Hdf5CompoundType(16)) {
            ct.addField("offset", HDF5Constants.H5T_NATIVE_UINT64, 0);
            ct.addVariableLengthStringField("name", 8);
        }
    }

    @Test
    @DisplayName("C2b #6: double close is idempotent")
    void doubleClose() {
        Hdf5CompoundType ct = new Hdf5CompoundType(8);
        ct.addField("x", HDF5Constants.H5T_NATIVE_UINT64, 0);
        ct.close();
        // Second close — no-op per implementation.
        assertDoesNotThrow(ct::close);
    }

    @Test
    @DisplayName("C2b #7: addField after close is silently no-op (locked behaviour)")
    void addFieldAfterClose() {
        Hdf5CompoundType ct = new Hdf5CompoundType(8);
        ct.close();
        // addField checks (closed || typeId < 0) and returns early.
        // Locks in the no-throw-after-close behaviour.
        assertDoesNotThrow(() ->
            ct.addField("ignored", HDF5Constants.H5T_NATIVE_UINT64, 0));
    }

    @Test
    @DisplayName("C2b #8: addVariableLengthStringField after close is no-op")
    void addVlStringAfterClose() {
        Hdf5CompoundType ct = new Hdf5CompoundType(8);
        ct.close();
        assertDoesNotThrow(() -> ct.addVariableLengthStringField("ignored", 0));
    }

    @Test
    @DisplayName("C2b #9: typeId returns -1 after close")
    void typeIdAfterClose() {
        Hdf5CompoundType ct = new Hdf5CompoundType(8);
        ct.addField("x", HDF5Constants.H5T_NATIVE_UINT64, 0);
        long tidBefore = ct.getTypeId();
        assertTrue(tidBefore >= 0);
        ct.close();
        assertEquals(-1, ct.getTypeId(), "getTypeId after close should be -1");
    }

    @Test
    @DisplayName("C2b #10: many VL string fields exercises auxTypeIds list growth")
    void manyVlStringFields() {
        // Each VL string allocates a separate aux type id. Tests the
        // ArrayList growth + cleanup loop.
        try (Hdf5CompoundType ct = new Hdf5CompoundType(80)) {
            for (int i = 0; i < 10; i++) {
                ct.addVariableLengthStringField("field" + i, i * 8);
            }
            // close() releases all 10 aux ids in the loop.
        }
    }
}
