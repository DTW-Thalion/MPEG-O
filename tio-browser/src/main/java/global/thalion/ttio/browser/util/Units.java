package global.thalion.ttio.browser.util;

import java.util.Locale;

public final class Units {
    private Units() {}

    private static final String[] BYTE_UNITS = {"B", "KB", "MB", "GB", "TB", "PB"};

    public static String humanBytes(long bytes) {
        if (bytes < 1024L) return bytes + " B";
        double v = bytes;
        int i = 0;
        while (v >= 1024.0 && i < BYTE_UNITS.length - 1) {
            v /= 1024.0;
            i++;
        }
        return String.format(Locale.ROOT, "%.1f %s", v, BYTE_UNITS[i]);
    }

    public static String humanRate(double bytesPerSec) {
        if (bytesPerSec < 1024.0) {
            return String.format(Locale.ROOT, "%.0f B/s", bytesPerSec);
        }
        double v = bytesPerSec;
        int i = 0;
        while (v >= 1024.0 && i < BYTE_UNITS.length - 1) {
            v /= 1024.0;
            i++;
        }
        return String.format(Locale.ROOT, "%.1f %s/s", v, BYTE_UNITS[i]);
    }

    public static String humanDuration(long seconds) {
        if (seconds < 60L) return seconds + "s";
        long m = seconds / 60L;
        long s = seconds % 60L;
        if (m < 60L) return m + "m " + s + "s";
        long h = m / 60L;
        m = m % 60L;
        if (h < 24L) return h + "h " + m + "m";
        long d = h / 24L;
        h = h % 24L;
        return d + "d " + h + "h";
    }

    public static String humanCount(long n) {
        return String.format(Locale.ROOT, "%,d", n);
    }
}
