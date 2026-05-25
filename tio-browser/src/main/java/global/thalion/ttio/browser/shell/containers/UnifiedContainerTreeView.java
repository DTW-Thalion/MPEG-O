/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.shell.containers;

import global.thalion.ttio.browser.workbench.ConnectionListener;
import global.thalion.ttio.browser.workbench.ConnectionManager;
import javafx.application.Platform;
import javafx.scene.control.TreeCell;
import javafx.scene.control.TreeItem;
import javafx.scene.control.TreeView;

/**
 * A {@link TreeView} that shows the unified Local + Servers container
 * hierarchy.
 *
 * <p>The Local branch is always present with its three action nodes
 * (Open, Encode, Import) and an optional Recent sub-group. The Servers
 * branch reflects the current {@link ConnectionManager} state: when
 * offline only a {@link UnifiedContainerNode.ServerConnectAction} is
 * shown; when connected a {@link UnifiedContainerNode.ServerRoot} is
 * added above it with lazy-loaded project children.</p>
 *
 * <p>Call {@link #dispose()} when the containing panel is removed from
 * the scene graph to release the {@link ConnectionListener}.</p>
 */
public final class UnifiedContainerTreeView {

    private final TreeView<UnifiedContainerNode> tree = new TreeView<>();
    private final ConnectionManager manager;
    private final ConnectionListener listener;
    private final TreeItem<UnifiedContainerNode> localRoot;
    private final TreeItem<UnifiedContainerNode> serversRoot;

    /** Cached roster from the last successful async load; {@code null} until populated. */
    private volatile ContainerRoster.Snapshot cachedRoster;

    /** Constructs using the process-wide {@link ConnectionManager#instance()}. */
    public UnifiedContainerTreeView() {
        this(ConnectionManager.instance());
    }

    /** Constructs using the supplied manager (primarily for tests). */
    public UnifiedContainerTreeView(ConnectionManager manager) {
        this.manager = manager;

        TreeItem<UnifiedContainerNode> hiddenRoot = new TreeItem<>(null);
        localRoot   = new TreeItem<>(new UnifiedContainerNode.LocalRoot());
        serversRoot = new TreeItem<>(new UnifiedContainerNode.ServersRoot());
        hiddenRoot.getChildren().addAll(localRoot, serversRoot);

        tree.setRoot(hiddenRoot);
        tree.setShowRoot(false);
        tree.setCellFactory(t -> new ActionStyledCell());

        seedLocalBranch();
        seedServersBranch();

        this.listener = (s, m) -> Platform.runLater(this::seedServersBranch);
        manager.addListener(listener);
    }

    /** Returns the underlying {@link TreeView} control for embedding in a scene. */
    public TreeView<UnifiedContainerNode> control() { return tree; }

    /** Releases the {@link ConnectionListener} registration. */
    public void dispose() { manager.removeListener(listener); }

    /**
     * Shows (or hides) a {@link UnifiedContainerNode.LocalOpenFile} at the
     * top of the Local branch. Pass {@code null} to remove it.
     */
    public void setOpenFile(String path) {
        localRoot.getChildren().removeIf(i ->
            i.getValue() instanceof UnifiedContainerNode.LocalOpenFile);
        if (path != null) {
            localRoot.getChildren().add(0,
                new TreeItem<>(new UnifiedContainerNode.LocalOpenFile(path)));
        }
    }

    // -----------------------------------------------------------------------
    // Private helpers
    // -----------------------------------------------------------------------

    private void seedLocalBranch() {
        localRoot.setExpanded(true);
        localRoot.getChildren().clear();
        TreeItem<UnifiedContainerNode> recent =
            new TreeItem<>(new UnifiedContainerNode.LocalRecentGroup());
        localRoot.getChildren().addAll(
            recent,
            new TreeItem<>(new UnifiedContainerNode.OpenLocalAction()),
            new TreeItem<>(new UnifiedContainerNode.EncodeLocalAction()),
            new TreeItem<>(new UnifiedContainerNode.ImportLocalAction()));
    }

    /** Returns the cached container roster, or {@code null} if the async load has not completed. */
    public ContainerRoster.Snapshot cachedRoster() { return cachedRoster; }

    private void seedServersBranch() {
        serversRoot.setExpanded(true);
        serversRoot.getChildren().clear();
        if (manager.isConnected()) {
            String userAtHost = manager.session().username()
                + "@" + manager.client().host();
            TreeItem<UnifiedContainerNode> server =
                new TreeItem<>(new UnifiedContainerNode.ServerRoot(userAtHost));
            server.setExpanded(true);
            server.getChildren().add(new TreeItem<>(
                new UnifiedContainerNode.ServerProject("(loading…)", 0)));
            serversRoot.getChildren().add(server);
            loadProjectsAsync(server);
        }
        serversRoot.getChildren().add(
            new TreeItem<>(new UnifiedContainerNode.ServerConnectAction()));
    }

    private void loadProjectsAsync(TreeItem<UnifiedContainerNode> serverItem) {
        final var client = manager.client();
        if (client == null) return;
        Thread t = new Thread(() -> {
            try {
                ContainerRoster.Snapshot snap =
                    ContainerRoster.fetchAndGroup(client, 200);
                Platform.runLater(() -> {
                    serverItem.getChildren().clear();
                    snap.byProject().forEach((proj, containers) ->
                        serverItem.getChildren().add(new TreeItem<>(
                            new UnifiedContainerNode.ServerProject(
                                proj, containers.size()))));
                    cachedRoster = snap;
                });
            } catch (Throwable ex) {
                Platform.runLater(() -> {
                    serverItem.getChildren().clear();
                    serverItem.getChildren().add(new TreeItem<>(
                        new UnifiedContainerNode.ServerProject(
                            "⚠ " + (ex.getMessage() == null
                                ? ex.getClass().getSimpleName()
                                : ex.getMessage()), 0)));
                });
            }
        }, "unified-tree-load-projects");
        t.setDaemon(true);
        t.start();
    }

    // -----------------------------------------------------------------------
    // Cell renderer
    // -----------------------------------------------------------------------

    private static final class ActionStyledCell extends TreeCell<UnifiedContainerNode> {
        @Override
        protected void updateItem(UnifiedContainerNode item, boolean empty) {
            super.updateItem(item, empty);
            if (empty || item == null) {
                setText(null);
                setStyle("");
            } else {
                setText(item.displayName());
                if (item.kind() == UnifiedContainerNode.Kind.ACTION) {
                    setStyle("-fx-font-style: italic; -fx-text-fill: -fx-accent;");
                } else {
                    setStyle("");
                }
            }
        }
    }
}
