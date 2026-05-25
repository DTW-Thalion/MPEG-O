package global.thalion.ttio.browser.progress;

import global.thalion.ttio.browser.util.Units;

import java.util.Locale;

public final class ProgressFormatter {
    private ProgressFormatter() {}

    private static final String DOT  = "·";
    private static final String DASH = "—";
    private static final String ELL  = "…";

    public static String line(ProgressReport r, long nowEpochMs) {
        if (r.isStalled(nowEpochMs)) {
            long quietSec = (nowEpochMs - r.lastActivityEpochMs()) / 1000L;
            return "stalled " + DASH + " last activity "
                + Units.humanDuration(quietSec) + " ago";
        }

        boolean haveBytesTotal = r.bytesTotal() > 0L;
        boolean haveUnitsTotal = r.unitsTotal() > 0L;
        boolean haveAnyTotal   = haveBytesTotal || haveUnitsTotal;

        StringBuilder sb = new StringBuilder();
        if (haveAnyTotal) {
            if (haveBytesTotal) {
                sb.append(String.format(Locale.ROOT, "%.1f%%",
                    r.percent() * 100.0));
                sb.append(' ').append(DOT).append(' ');
            }
            if (haveBytesTotal && haveUnitsTotal) {
                sb.append(rawBytesPair(r)).append(' ').append(DOT).append(' ')
                  .append(Units.humanCount(r.unitsDone())).append(" AUs");
            } else if (haveBytesTotal) {
                sb.append(rawBytesPair(r));
            } else {
                sb.append(Units.humanCount(r.unitsDone()))
                  .append(" / ")
                  .append(Units.humanCount(r.unitsTotal()))
                  .append(" AUs");
            }
        } else {
            sb.append(Units.humanBytes(r.bytesDone())).append(" processed");
        }

        sb.append(' ').append(DOT).append(' ');
        if (Double.isNaN(r.rateBytesPerSec()) && Double.isNaN(r.rateUnitsPerSec())) {
            sb.append("measuring rate").append(ELL);
        } else if (haveUnitsTotal && !haveBytesTotal) {
            sb.append(String.format(Locale.ROOT, "%.0f AU/s",
                r.rateUnitsPerSec()));
        } else {
            sb.append(Units.humanRate(r.rateBytesPerSec()));
        }

        if (r.etaSeconds() >= 0L) {
            sb.append(' ').append(DOT).append(' ');
            sb.append("ETA ").append(Units.humanDuration(r.etaSeconds()));
        } else if (!haveAnyTotal) {
            sb.append(' ').append(DOT).append(' ');
            sb.append("elapsed ").append(Units.humanDuration(r.elapsedSeconds()));
        }

        return sb.toString();
    }

    private static String rawBytesPair(ProgressReport r) {
        return Units.humanBytes(r.bytesDone()) + " / "
             + Units.humanBytes(r.bytesTotal());
    }
}
