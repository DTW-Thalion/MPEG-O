/* MPEG-O Java Implementation / Copyright (C) 2026 DTW-Thalion / SPDX-License-Identifier: Apache-2.0 */
package com.dtwthalion.mpgo.importers;

public class ThermoRawReader {
    private ThermoRawReader() {}

    public static void read(String path) {
        throw new UnsupportedOperationException(
            "Thermo RAW import requires the Thermo Fisher RawFileReader SDK. " +
            "See https://github.com/thermofisher/RawFileReader for licensing and setup. " +
            "Convert .raw to .mzML using msconvert (ProteoWizard) as an alternative.");
    }
}
