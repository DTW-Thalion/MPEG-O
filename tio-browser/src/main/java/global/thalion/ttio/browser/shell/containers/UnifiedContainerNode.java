/*
 * TTI-O tio-browser
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.browser.shell.containers;

/**
 * Sealed node hierarchy for the unified container tree.
 *
 * <p>Each variant represents either a group/root header, an action
 * pseudo-row, or a real data entity (local file, server project, or
 * server container). The sealed interface lets the tree-cell renderer
 * use an exhaustive switch/pattern-match without a catch-all branch.</p>
 */
public sealed interface UnifiedContainerNode {

    enum Kind { GROUP, ACTION, CONTAINER, PROJECT, SERVER, LOCAL_FILE, RECENT }

    String displayName();
    Kind kind();

    record LocalRoot() implements UnifiedContainerNode {
        public String displayName() { return "Local"; }
        public Kind kind() { return Kind.GROUP; }
    }
    record LocalOpenFile(String path) implements UnifiedContainerNode {
        public String displayName() {
            return java.nio.file.Paths.get(path).getFileName().toString();
        }
        public Kind kind() { return Kind.LOCAL_FILE; }
    }
    record LocalRecentGroup() implements UnifiedContainerNode {
        public String displayName() { return "Recent"; }
        public Kind kind() { return Kind.GROUP; }
    }
    record LocalRecentEntry(String path) implements UnifiedContainerNode {
        public String displayName() {
            return java.nio.file.Paths.get(path).getFileName().toString();
        }
        public Kind kind() { return Kind.RECENT; }
    }
    record OpenLocalAction() implements UnifiedContainerNode {
        public String displayName() { return "+ Open file…"; }
        public Kind kind() { return Kind.ACTION; }
    }
    record EncodeLocalAction() implements UnifiedContainerNode {
        public String displayName() { return "+ Encode…"; }
        public Kind kind() { return Kind.ACTION; }
    }
    record ImportLocalAction() implements UnifiedContainerNode {
        public String displayName() { return "+ Import…"; }
        public Kind kind() { return Kind.ACTION; }
    }
    record ServersRoot() implements UnifiedContainerNode {
        public String displayName() { return "Servers"; }
        public Kind kind() { return Kind.GROUP; }
    }
    record ServerRoot(String userAtHost) implements UnifiedContainerNode {
        public String displayName() { return userAtHost; }
        public Kind kind() { return Kind.SERVER; }
    }
    record ServerProject(String name, int containerCount) implements UnifiedContainerNode {
        public String displayName() { return "Project: " + name + " (" + containerCount + ")"; }
        public Kind kind() { return Kind.PROJECT; }
    }
    record ServerContainer(String uri, String displayName, long sizeBytes)
            implements UnifiedContainerNode {
        public Kind kind() { return Kind.CONTAINER; }
    }
    record ServerConnectAction() implements UnifiedContainerNode {
        public String displayName() { return "+ Connect another server…"; }
        public Kind kind() { return Kind.ACTION; }
    }
}
