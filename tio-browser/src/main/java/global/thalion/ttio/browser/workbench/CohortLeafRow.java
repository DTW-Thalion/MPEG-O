/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import global.thalion.ttio.workbench.cohort.CohortPredicate;
import javafx.beans.property.SimpleStringProperty;
import javafx.beans.property.StringProperty;

import java.util.Locale;

/**
 * One row in the {@link CohortQueryBuilder}'s leaf-predicate
 * table. Captures kind / field / op / value and converts to a
 * {@link CohortPredicate} leaf when the user submits.
 *
 * <p>Kept as a separate type so the GUI's TableView<CohortLeafRow>
 * binds cleanly via JavaFX properties.</p>
 */
public final class CohortLeafRow {

    /** Leaf kind: container_field / subject_field / sample_field
     *  / phenotype. */
    public enum Kind {
        CONTAINER,
        SUBJECT,
        SAMPLE,
        PHENOTYPE;

        public String label() {
            return switch (this) {
                case CONTAINER -> "container_field";
                case SUBJECT   -> "subject_field";
                case SAMPLE    -> "sample_field";
                case PHENOTYPE -> "phenotype";
            };
        }

        public static Kind fromLabel(String label) {
            for (Kind k : values()) {
                if (k.label().equals(label)) return k;
            }
            throw new IllegalArgumentException("unknown kind label: " + label);
        }
    }

    private final StringProperty kindLabel  = new SimpleStringProperty(Kind.CONTAINER.label());
    private final StringProperty field      = new SimpleStringProperty("");
    private final StringProperty op         = new SimpleStringProperty("eq");
    private final StringProperty rawValue   = new SimpleStringProperty("");

    public StringProperty kindLabelProperty() { return kindLabel; }
    public StringProperty fieldProperty()      { return field; }
    public StringProperty opProperty()         { return op; }
    public StringProperty rawValueProperty()   { return rawValue; }

    public Kind   kind()      { return Kind.fromLabel(kindLabel.get()); }
    public String field()     { return field.get(); }
    public String op()        { return op.get(); }
    public String rawValue()  { return rawValue.get(); }

    public void setKind(Kind k)            { this.kindLabel.set(k.label()); }
    public void setField(String s)          { this.field.set(s); }
    public void setOp(String s)             { this.op.set(s); }
    public void setRawValue(String s)       { this.rawValue.set(s); }

    /** Build the corresponding {@link CohortPredicate} leaf. Bad
     *  input surfaces as {@link IllegalArgumentException}. */
    public CohortPredicate toPredicate() {
        String f = field();
        String o = op();
        if (f == null || f.isBlank()) {
            throw new IllegalArgumentException(
                "field required for " + kindLabel.get() + " predicate");
        }
        Object value = coerceValue(rawValue(), o);
        return switch (kind()) {
            case CONTAINER -> CohortPredicate.container(f, o, value);
            case SUBJECT   -> CohortPredicate.subject(f, o, value);
            case SAMPLE    -> CohortPredicate.sample(f, o, value);
            case PHENOTYPE -> CohortPredicate.phenotype(f, o, value);
        };
    }

    /** Coerce the raw text input to a typed value matching the
     *  operator semantics. {@code exists} ignores the value;
     *  numeric literals are parsed greedily; {@code in} accepts a
     *  comma-separated list. Anything else stays as a string. */
    public static Object coerceValue(String raw, String op) {
        String trimmed = raw == null ? "" : raw.trim();
        if ("exists".equals(op)) {
            // Server tolerates any value; the predicate's JSON
            // builder may not require it.
            if (trimmed.isEmpty()) return Boolean.TRUE;
            return parseScalarOrString(trimmed);
        }
        if ("in".equals(op)) {
            // comma-separated list -> List<Object>
            java.util.List<Object> out = new java.util.ArrayList<>();
            if (trimmed.isEmpty()) return out;
            for (String part : trimmed.split(",")) {
                String t = part.trim();
                if (!t.isEmpty()) out.add(parseScalarOrString(t));
            }
            return out;
        }
        if (trimmed.isEmpty()) return "";
        return parseScalarOrString(trimmed);
    }

    private static Object parseScalarOrString(String s) {
        // Try int first (broad set in cohort queries).
        try { return Long.parseLong(s); } catch (NumberFormatException ignored) {}
        try { return Double.parseDouble(s); } catch (NumberFormatException ignored) {}
        // bool literals
        String lc = s.toLowerCase(Locale.ROOT);
        if ("true".equals(lc))  return Boolean.TRUE;
        if ("false".equals(lc)) return Boolean.FALSE;
        return s;
    }
}
