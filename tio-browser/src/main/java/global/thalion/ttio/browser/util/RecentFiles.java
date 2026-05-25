package global.thalion.ttio.browser.util;

import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.prefs.Preferences;

/**
 * Persisted MRU list of recently-opened .tio paths. Backed by
 * java.util.prefs.Preferences (no new dependency). Paths are
 * base64-encoded for safety with any character set.
 */
public final class RecentFiles {

    private final Preferences prefs;
    private final int cap;
    private static final String KEY = "recent";

    public RecentFiles(String prefKey, int cap) {
        this.prefs = Preferences.userNodeForPackage(RecentFiles.class).node(prefKey);
        this.cap = cap;
    }

    public synchronized void record(String path) {
        if (path == null || path.isBlank()) return;
        List<String> list = new ArrayList<>(recent());
        list.remove(path);
        list.add(0, path);
        if (list.size() > cap) list = list.subList(0, cap);
        save(list);
    }

    public synchronized List<String> recent() {
        String csv = prefs.get(KEY, "");
        if (csv.isEmpty()) return List.of();
        List<String> out = new ArrayList<>();
        for (String tok : csv.split(",")) {
            if (tok.isEmpty()) continue;
            out.add(new String(Base64.getDecoder().decode(tok)));
        }
        return out;
    }

    public synchronized void clearForTest() {
        prefs.remove(KEY);
    }

    private void save(List<String> list) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < list.size(); i++) {
            if (i > 0) sb.append(',');
            sb.append(Base64.getEncoder().encodeToString(list.get(i).getBytes()));
        }
        prefs.put(KEY, sb.toString());
    }
}
