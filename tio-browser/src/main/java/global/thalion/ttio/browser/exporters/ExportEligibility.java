package global.thalion.ttio.browser.exporters;

import global.thalion.ttio.AcquisitionRun;
import global.thalion.ttio.Enums;
import global.thalion.ttio.browser.model.OpenDataset;

/**
 * Pure-Java predicate over an {@link OpenDataset} for each
 * {@link ExportFormatSpec.Eligibility} value. The {@link ExportDialog}
 * uses {@link #check} to grey out ineligible rows and
 * {@link #tooltipReason} to surface the reason on hover.
 */
public final class ExportEligibility {

    private ExportEligibility() {}

    public static boolean check(ExportFormatSpec spec, OpenDataset d) {
        switch (spec.eligibility) {
            case ALWAYS:
                return true;
            case MS_RUNS_PRESENT:
                return d.msRunCount() > 0;
            case NMR_RUNS_PRESENT:
                return anyAnalyticalRunMatching(d, ExportEligibility::isNmr);
            case RAMAN_OR_IR_OR_UVVIS_PRESENT:
                return anyAnalyticalRunMatching(d, ExportEligibility::isRamanIrOrUvVis);
            case GENOMIC_RUNS_PRESENT:
                return d.genomicRunCount() > 0;
            case REFERENCES_PRESENT:
                return d.referenceCount() > 0;
            case MS_IMAGE_PRESENT:
                return d.dataset().image() != null
                    || anyAnalyticalRunMatching(d, ExportEligibility::hasMsImageSpectrum);
            case IDENTS_OR_QUANTS_PRESENT:
                return d.identificationCount() > 0 || d.quantificationCount() > 0;
        }
        return false;
    }

    public static String tooltipReason(ExportFormatSpec spec, OpenDataset d) {
        if (!spec.binaryAvailable()) {
            return "Requires `" + spec.requiredBinary + "` on PATH";
        }
        if (check(spec, d)) return spec.description;
        switch (spec.eligibility) {
            case MS_RUNS_PRESENT:           return "No MS runs in this file.";
            case NMR_RUNS_PRESENT:          return "No NMR runs in this file.";
            case RAMAN_OR_IR_OR_UVVIS_PRESENT:
                return "No Raman / IR / UV-Vis spectra in this file.";
            case GENOMIC_RUNS_PRESENT:      return "No genomic runs in this file.";
            case REFERENCES_PRESENT:        return "No embedded references in this file.";
            case MS_IMAGE_PRESENT:          return "No MSImage runs in this file.";
            case IDENTS_OR_QUANTS_PRESENT:
                return "No identifications or quantifications in this file.";
            case ALWAYS:
            default:                        return spec.description;
        }
    }

    @FunctionalInterface
    private interface RunPredicate {
        boolean test(AcquisitionRun run);
    }

    private static boolean anyAnalyticalRunMatching(OpenDataset d, RunPredicate p) {
        for (AcquisitionRun run : d.dataset().msRuns().values()) {
            if (p.test(run)) return true;
        }
        return false;
    }

    private static boolean isNmr(AcquisitionRun r) {
        Enums.AcquisitionMode m = r.acquisitionMode();
        return m == Enums.AcquisitionMode.NMR_1D
            || m == Enums.AcquisitionMode.NMR_2D;
    }

    private static boolean isRamanIrOrUvVis(AcquisitionRun r) {
        Enums.AcquisitionMode m = r.acquisitionMode();
        return m == Enums.AcquisitionMode.RAMAN
            || m == Enums.AcquisitionMode.IR
            || m == Enums.AcquisitionMode.UV_VIS;
    }

    private static boolean hasMsImageSpectrum(AcquisitionRun r) {
        return r.acquisitionMode() == Enums.AcquisitionMode.IMAGING;
    }
}
