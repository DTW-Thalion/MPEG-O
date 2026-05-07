package global.thalion.ttio.browser.model;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Objects;

public final class DatasetTreeNode {

    private final TreeNodeKind kind;
    private final String label;
    private final String key;
    private final List<DatasetTreeNode> children = new ArrayList<>();

    public DatasetTreeNode(TreeNodeKind kind, String label, String key) {
        this.kind = Objects.requireNonNull(kind);
        this.label = Objects.requireNonNull(label);
        this.key = key;
    }

    public TreeNodeKind kind() { return kind; }
    public String label()      { return label; }
    public String key()        { return key; }
    public List<DatasetTreeNode> children() { return Collections.unmodifiableList(children); }

    public DatasetTreeNode add(DatasetTreeNode child) {
        children.add(child);
        return this;
    }

    @Override
    public String toString() { return kind + "[" + label + "]"; }
}
