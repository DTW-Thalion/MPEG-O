/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: Apache-2.0
 */
package com.dtwthalion.mpgo.importers;

import com.dtwthalion.mpgo.Enums.*;
import java.util.Map;

public final class CVTermMapper {
    private CVTermMapper() {}

    // Precision accessions
    public static final String MS_32BIT_FLOAT = "MS:1000521";
    public static final String MS_64BIT_FLOAT = "MS:1000523";
    public static final String MS_32BIT_INT = "MS:1000519";
    public static final String MS_64BIT_INT = "MS:1000522";

    // Compression accessions
    public static final String MS_ZLIB = "MS:1000574";
    public static final String MS_NO_COMPRESSION = "MS:1000576";

    // Array role accessions
    public static final String MS_MZ_ARRAY = "MS:1000514";
    public static final String MS_INTENSITY_ARRAY = "MS:1000515";
    public static final String MS_CHARGE_ARRAY = "MS:1000516";
    public static final String MS_SNR_ARRAY = "MS:1000517";
    public static final String MS_TIME_ARRAY = "MS:1000595";
    public static final String MS_WAVELENGTH_ARRAY = "MS:1000617";
    public static final String MS_ION_MOBILITY_ARRAY = "MS:1000820";

    // Spectrum metadata
    public static final String MS_MS_LEVEL = "MS:1000511";
    public static final String MS_POSITIVE_SCAN = "MS:1000130";
    public static final String MS_NEGATIVE_SCAN = "MS:1000129";
    public static final String MS_SCAN_START_TIME = "MS:1000016";
    public static final String MS_SELECTED_ION_MZ = "MS:1000744";
    public static final String MS_CHARGE_STATE = "MS:1000041";
    public static final String MS_SCAN_WIN_LOWER = "MS:1000501";
    public static final String MS_SCAN_WIN_UPPER = "MS:1000500";
    public static final String MS_BASE_PEAK_INTENSITY = "MS:1000505";
    public static final String MS_TIC = "MS:1000285";

    // Chromatogram types
    public static final String MS_TIC_CHROM = "MS:1000235";
    public static final String MS_XIC_CHROM = "MS:1000627";
    public static final String MS_SRM_CHROM = "MS:1001473";

    // Unit accessions
    public static final String UO_MINUTE = "UO:0000031";

    // nmrCV
    public static final String NMR_FREQ = "NMR:1000001";
    public static final String NMR_NUCLEUS = "NMR:1000002";
    public static final String NMR_NUM_SCANS = "NMR:1000003";
    public static final String NMR_DWELL_TIME = "NMR:1000004";
    public static final String NMR_SWEEP_WIDTH = "NMR:1400014";

    private static final Map<String, String> ARRAY_ROLE_MAP = Map.of(
        MS_MZ_ARRAY, "mz",
        MS_INTENSITY_ARRAY, "intensity",
        MS_CHARGE_ARRAY, "charge",
        MS_SNR_ARRAY, "signal_to_noise",
        MS_TIME_ARRAY, "time",
        MS_WAVELENGTH_ARRAY, "wavelength",
        MS_ION_MOBILITY_ARRAY, "ion_mobility"
    );

    public static String arrayRoleFor(String accession) {
        return ARRAY_ROLE_MAP.get(accession);
    }

    public static Precision precisionFor(String accession) {
        return switch (accession) {
            case MS_32BIT_FLOAT -> Precision.FLOAT32;
            case MS_64BIT_FLOAT -> Precision.FLOAT64;
            case MS_32BIT_INT -> Precision.INT32;
            case MS_64BIT_INT -> Precision.INT64;
            default -> null;
        };
    }

    public static boolean isZlib(String accession) {
        return MS_ZLIB.equals(accession);
    }

    // Reverse mappings for export
    public static final String EXPORT_MZ_ACCESSION = MS_MZ_ARRAY;
    public static final String EXPORT_INTENSITY_ACCESSION = MS_INTENSITY_ARRAY;
    public static final String EXPORT_MZ_UNIT = "MS:1000040";
    public static final String EXPORT_INTENSITY_UNIT = "MS:1000131";

    public static String nucleusNormalize(String raw) {
        if (raw == null) return null;
        String lower = raw.toLowerCase();
        if (lower.contains("hydrogen") || lower.equals("1h")) return "1H";
        if (lower.contains("carbon") || lower.equals("13c")) return "13C";
        if (lower.contains("nitrogen") || lower.equals("15n")) return "15N";
        if (lower.contains("phosphorus") || lower.equals("31p")) return "31P";
        return raw;
    }
}
