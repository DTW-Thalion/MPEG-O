package global.thalion.ttio.browser.shell;

import javafx.scene.control.ToggleButton;
import javafx.scene.control.ToggleGroup;
import javafx.scene.control.Tooltip;
import javafx.scene.layout.VBox;
import javafx.util.Duration;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Consumer;

public final class ActivityRail {

    private final VBox root = new VBox();
    private final ToggleGroup group = new ToggleGroup();
    private final Map<String, ToggleButton> buttons = new LinkedHashMap<>();
    private final List<Workspace> workspaces;
    private Consumer<String> onSelect = k -> {};
    private String selected;

    public ActivityRail(List<Workspace> workspaces) {
        this.workspaces = List.copyOf(workspaces);
        root.getStyleClass().add("activity-rail");
        root.setPrefWidth(48);
        root.setMinWidth(48);
        root.setMaxWidth(48);
        for (Workspace w : this.workspaces) {
            ToggleButton b = new ToggleButton(w.iconText());
            b.setToggleGroup(group);
            b.getStyleClass().add("activity-rail-button");
            b.setPrefSize(48, 48);
            Tooltip t = new Tooltip(w.tooltip());
            t.setShowDelay(Duration.millis(600));
            b.setTooltip(t);
            b.setOnAction(e -> {
                if (!b.isSelected()) {
                    // Prevent deselecting the only selected button.
                    b.setSelected(true);
                    return;
                }
                select(w.key());
            });
            buttons.put(w.key(), b);
            root.getChildren().add(b);
        }
        if (!this.workspaces.isEmpty()) {
            select(this.workspaces.get(0).key());
        }
    }

    public VBox node() { return root; }

    public String selectedKey() { return selected; }

    public void select(String key) {
        ToggleButton b = buttons.get(key);
        if (b == null) return;
        b.setSelected(true);
        if (!key.equals(selected)) {
            selected = key;
            onSelect.accept(key);
        }
    }

    public void onSelect(Consumer<String> handler) {
        this.onSelect = handler == null ? k -> {} : handler;
    }

    /** Test-only accessor. */
    java.util.Collection<ToggleButton> buttonsForTest() {
        return buttons.values();
    }
}
