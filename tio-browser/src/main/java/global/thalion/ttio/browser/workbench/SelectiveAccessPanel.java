/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.workbench;

import global.thalion.ttio.workbench.transport.SelectiveAccessFilter;
import javafx.collections.FXCollections;
import javafx.geometry.Insets;
import javafx.scene.control.ChoiceBox;
import javafx.scene.control.Label;
import javafx.scene.control.TextField;
import javafx.scene.layout.GridPane;

import java.util.Map;

/**
 * Embeddable filter form for the download dialog. Visual mirror of
 * the SDK's {@link SelectiveAccessFilter} typed-setter surface --
 * one row per accepted filter key.
 *
 * <p>{@link #buildFilter()} validates per-field, then runs the
 * cross-key {@code validate()} pass, throwing
 * {@link IllegalArgumentException} (per-key) or
 * {@link IllegalStateException} (cross-key) on bad input.</p>
 */
public final class SelectiveAccessPanel {

    private static final String POLARITY_BLANK = "(any)";

    private final GridPane grid = new GridPane();
    private final TextField msLevelField = new TextField();
    private final ChoiceBox<String> polarityBox = new ChoiceBox<>();
    private final TextField rtMinField = new TextField();
    private final TextField rtMaxField = new TextField();
    private final TextField mzMinField = new TextField();
    private final TextField mzMaxField = new TextField();
    private final TextField chargeField = new TextField();
    private final TextField maxAuField = new TextField();

    public SelectiveAccessPanel() {
        buildUi();
    }

    public GridPane node() { return grid; }

    // ---- package-private accessors for TestFX ----

    TextField msLevelField()    { return msLevelField; }
    ChoiceBox<String> polarityBox() { return polarityBox; }
    TextField rtMinField()      { return rtMinField; }
    TextField rtMaxField()      { return rtMaxField; }
    TextField mzMinField()      { return mzMinField; }
    TextField mzMaxField()      { return mzMaxField; }
    TextField chargeField()     { return chargeField; }
    TextField maxAuField()      { return maxAuField; }

    /** Build a server-ready filter map from the current form state.
     *  Empty fields are omitted (no filter on that key). */
    public Map<String, Object> buildFilter() {
        SelectiveAccessFilter b = new SelectiveAccessFilter();
        Integer ms = parseInt(msLevelField.getText());
        if (ms != null) b.msLevel(ms);
        String pol = polarityBox.getValue();
        if (pol != null && !POLARITY_BLANK.equals(pol)) b.polarity(pol);
        Double rtMin = parseDouble(rtMinField.getText());
        if (rtMin != null) b.retentionTimeMin(rtMin);
        Double rtMax = parseDouble(rtMaxField.getText());
        if (rtMax != null) b.retentionTimeMax(rtMax);
        Double mzMin = parseDouble(mzMinField.getText());
        if (mzMin != null) b.precursorMzMin(mzMin);
        Double mzMax = parseDouble(mzMaxField.getText());
        if (mzMax != null) b.precursorMzMax(mzMax);
        Integer charge = parseInt(chargeField.getText());
        if (charge != null) b.precursorCharge(charge);
        Integer maxAu = parseInt(maxAuField.getText());
        if (maxAu != null) b.maxAu(maxAu);
        return b.validate().build();
    }

    /** Reset every field to its empty default. */
    public void clear() {
        msLevelField.clear();
        polarityBox.setValue(POLARITY_BLANK);
        rtMinField.clear();
        rtMaxField.clear();
        mzMinField.clear();
        mzMaxField.clear();
        chargeField.clear();
        maxAuField.clear();
    }

    // ---- static helpers (pure -- testable without FX) ----

    /** Parse a positive integer; blank / non-numeric / non-positive
     *  return null (so the corresponding filter key is skipped). */
    public static Integer parseInt(String raw) {
        if (raw == null) return null;
        String t = raw.trim();
        if (t.isEmpty()) return null;
        try {
            int n = Integer.parseInt(t);
            return n > 0 ? n : null;
        } catch (NumberFormatException ex) {
            return null;
        }
    }

    /** Parse a non-negative double; blank / non-numeric / negative
     *  return null (so the corresponding filter key is skipped). */
    public static Double parseDouble(String raw) {
        if (raw == null) return null;
        String t = raw.trim();
        if (t.isEmpty()) return null;
        try {
            double d = Double.parseDouble(t);
            return d >= 0 ? d : null;
        } catch (NumberFormatException ex) {
            return null;
        }
    }

    // ---- UI ----

    private void buildUi() {
        polarityBox.setItems(FXCollections.observableArrayList(
            POLARITY_BLANK, "positive", "negative"));
        polarityBox.setValue(POLARITY_BLANK);

        grid.setHgap(8);
        grid.setVgap(6);
        grid.setPadding(new Insets(8));
        int row = 0;
        grid.add(new Label("MS level:"), 0, row);
        grid.add(msLevelField, 1, row); row++;
        grid.add(new Label("Polarity:"), 0, row);
        grid.add(polarityBox, 1, row); row++;
        grid.add(new Label("RT min (s):"), 0, row);
        grid.add(rtMinField, 1, row); row++;
        grid.add(new Label("RT max (s):"), 0, row);
        grid.add(rtMaxField, 1, row); row++;
        grid.add(new Label("Precursor m/z min:"), 0, row);
        grid.add(mzMinField, 1, row); row++;
        grid.add(new Label("Precursor m/z max:"), 0, row);
        grid.add(mzMaxField, 1, row); row++;
        grid.add(new Label("Precursor charge:"), 0, row);
        grid.add(chargeField, 1, row); row++;
        grid.add(new Label("Max AU:"), 0, row);
        grid.add(maxAuField, 1, row); row++;
    }
}
