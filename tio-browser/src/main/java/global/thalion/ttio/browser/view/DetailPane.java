package global.thalion.ttio.browser.view;

import global.thalion.ttio.browser.model.DatasetTreeNode;
import global.thalion.ttio.browser.model.OpenDataset;
import javafx.scene.control.Tab;
import javafx.scene.control.TabPane;

import java.util.ArrayList;
import java.util.List;

public class DetailPane {

    private final TabPane tabs = new TabPane();
    private final List<AbstractDetailTab> registered = new ArrayList<>();
    private OpenDataset currentDataset;

    public DetailPane() {
        tabs.setTabClosingPolicy(TabPane.TabClosingPolicy.UNAVAILABLE);
    }

    public TabPane control() { return tabs; }

    public void register(AbstractDetailTab tab) { registered.add(tab); }

    public void setCurrentDataset(OpenDataset d) {
        this.currentDataset = d;
        if (d == null) tabs.getTabs().clear();
    }

    public void onSelection(DatasetTreeNode selection) {
        tabs.getTabs().clear();
        if (currentDataset == null || selection == null) return;
        for (AbstractDetailTab t : registered) {
            if (t.appliesTo(selection)) {
                t.update(currentDataset, selection);
                Tab fxTab = new Tab(t.title(), t.content());
                fxTab.setClosable(false);
                tabs.getTabs().add(fxTab);
            }
        }
    }
}
