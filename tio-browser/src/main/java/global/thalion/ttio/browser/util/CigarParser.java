package global.thalion.ttio.browser.util;

import java.util.ArrayList;
import java.util.List;

/**
 * Minimal SAM/BAM CIGAR string parser. Handles the standard 9 ops
 * defined in the SAM spec: M, I, D, N, S, H, P, =, X (= → EQ).
 *
 * <p>{@link #parseCapped(String, int)} returns at most {@code max}
 * parsed ops plus the total count and a truncation flag — useful for
 * UI cells that need to display the first few ops without paying the
 * full parse cost on a 100K-op reference alignment.</p>
 */
public final class CigarParser {

    public enum Op { M, I, D, N, S, H, P, EQ, X }

    public record CigarOp(int length, Op op) {}

    public record CappedResult(List<CigarOp> ops, int totalOps, boolean truncated) {}

    private CigarParser() {}

    public static List<CigarOp> parse(String cigar) {
        if (cigar == null) throw new IllegalArgumentException("cigar must be non-null");
        if (cigar.isEmpty() || cigar.equals("*")) return List.of();
        List<CigarOp> out = new ArrayList<>();
        int i = 0;
        int n = cigar.length();
        boolean sawAny = false;
        while (i < n) {
            int start = i;
            while (i < n && Character.isDigit(cigar.charAt(i))) i++;
            if (i == start) {
                throw new IllegalArgumentException(
                    "invalid CIGAR: expected digit at index " + i + " in: " + cigar);
            }
            int length = Integer.parseInt(cigar.substring(start, i));
            if (i >= n) {
                throw new IllegalArgumentException(
                    "invalid CIGAR: trailing length without op: " + cigar);
            }
            Op op = decodeOp(cigar.charAt(i));
            i++;
            out.add(new CigarOp(length, op));
            sawAny = true;
        }
        if (!sawAny) {
            throw new IllegalArgumentException("invalid CIGAR: no ops parsed from: " + cigar);
        }
        return out;
    }

    public static CappedResult parseCapped(String cigar, int max) {
        if (max < 0) throw new IllegalArgumentException("max must be non-negative");
        List<CigarOp> all = parse(cigar);
        int total = all.size();
        if (total <= max) {
            return new CappedResult(all, total, false);
        }
        return new CappedResult(new ArrayList<>(all.subList(0, max)), total, true);
    }

    private static Op decodeOp(char c) {
        return switch (c) {
            case 'M' -> Op.M;
            case 'I' -> Op.I;
            case 'D' -> Op.D;
            case 'N' -> Op.N;
            case 'S' -> Op.S;
            case 'H' -> Op.H;
            case 'P' -> Op.P;
            case '=' -> Op.EQ;
            case 'X' -> Op.X;
            default -> throw new IllegalArgumentException(
                "invalid CIGAR op character: '" + c + "'");
        };
    }
}
