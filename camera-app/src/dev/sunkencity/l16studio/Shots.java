package dev.sunkencity.l16studio;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Environment;
import android.os.StatFs;
import android.util.LruCache;

import java.io.File;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * The shots on the camera. The stock camera app writes each shot to
 * DCIM/Camera as a pair: L16_NNNNN.lri (the raw file, ~160 MB) and
 * L16_NNNNN.jpg (a preview rendered in-camera).
 */
final class Shots {
    static final File FOLDER = new File(Environment.getExternalStorageDirectory(), "DCIM/Camera");

    /** One shot: its raw file and, when present, its preview. */
    static final class Shot {
        final String name;   // "L16_00001"
        final File raw;      // may not exist if only a preview is left
        final File preview;  // may not exist while the camera is still rendering it

        Shot(String name) {
            this.name = name;
            this.raw = new File(FOLDER, name + ".lri");
            this.preview = new File(FOLDER, name + ".jpg");
        }

        long modified() {
            return raw.exists() ? raw.lastModified() : preview.lastModified();
        }

        long size() {
            return (raw.exists() ? raw.length() : 0) + (preview.exists() ? preview.length() : 0);
        }

        /** True for a picture saved from the editor (it has no raw file). */
        boolean isEdit() {
            return !raw.exists() && name.contains("_edit");
        }

        /** Short label for the gallery: "00002", or "00002 · Vivid" for an edit. */
        String label() {
            String base = name.startsWith("L16_") ? name.substring(4) : name;
            int cut = base.indexOf("_edit");
            if (cut < 0) return raw.exists() ? base : base + "  · preview only";
            String style = base.substring(cut + 5).replace("_", " ").trim();
            return base.substring(0, cut) + (style.isEmpty() ? "  · edited" : "  · " + style);
        }

        /** Deletes both files. Returns true if nothing of the shot is left. */
        boolean delete() {
            boolean ok = true;
            if (raw.exists()) ok &= raw.delete();
            if (preview.exists()) ok &= preview.delete();
            return ok;
        }
    }

    /** Newest first. */
    static List<Shot> list() {
        Map<String, Shot> byName = new HashMap<>();
        File[] files = FOLDER.listFiles();
        if (files != null) {
            for (File f : files) {
                if (!f.isFile()) continue;
                String n = f.getName();
                String lower = n.toLowerCase();
                if (!lower.endsWith(".lri") && !lower.endsWith(".jpg")) continue;
                String base = n.substring(0, n.length() - 4);
                if (!byName.containsKey(base)) byName.put(base, new Shot(base));
            }
        }
        List<Shot> shots = new ArrayList<>(byName.values());
        Collections.sort(shots, new Comparator<Shot>() {
            @Override public int compare(Shot a, Shot b) {
                int byTime = Long.compare(b.modified(), a.modified());
                return byTime != 0 ? byTime : b.name.compareTo(a.name);
            }
        });
        return shots;
    }

    static Shot find(String name) {
        Shot s = new Shot(name);
        return (s.raw.exists() || s.preview.exists()) ? s : null;
    }

    static long freeBytes() {
        try {
            StatFs fs = new StatFs(Environment.getExternalStorageDirectory().getPath());
            return fs.getAvailableBytes();
        } catch (IllegalArgumentException e) {
            return 0;
        }
    }

    static String formatSize(long bytes) {
        if (bytes >= 1L << 30) return String.format("%.1f GB", bytes / (double) (1L << 30));
        if (bytes >= 1L << 20) return String.format("%.0f MB", bytes / (double) (1L << 20));
        return String.format("%.0f KB", bytes / 1024.0);
    }

    // ---- previews -------------------------------------------------------

    private static final LruCache<String, Bitmap> THUMBS =
            new LruCache<String, Bitmap>(48 * 1024 * 1024) {
                @Override protected int sizeOf(String key, Bitmap value) {
                    return value.getByteCount();
                }
            };

    static Bitmap cachedThumb(Shot shot) {
        return THUMBS.get(key(shot));
    }

    private static String key(Shot shot) {
        return shot.name + ":" + shot.preview.lastModified();
    }

    /** Decodes a small version of the preview (blocking; call off the UI thread). */
    static Bitmap loadThumb(Shot shot, int targetWidth) {
        Bitmap hit = cachedThumb(shot);
        if (hit != null) return hit;
        Bitmap bitmap = decode(shot.preview, targetWidth);
        if (bitmap != null) THUMBS.put(key(shot), bitmap);
        return bitmap;
    }

    /** Decodes `file` so its width is at least `targetWidth`, using power-of-two subsampling. */
    static Bitmap decode(File file, int targetWidth) {
        return decode(file, targetWidth, Bitmap.Config.RGB_565);
    }

    /** As above, with an explicit pixel format (editing needs ARGB_8888). */
    static Bitmap decode(File file, int targetWidth, Bitmap.Config config) {
        if (!file.exists()) return null;
        BitmapFactory.Options bounds = new BitmapFactory.Options();
        bounds.inJustDecodeBounds = true;
        BitmapFactory.decodeFile(file.getPath(), bounds);
        if (bounds.outWidth <= 0) return null;
        int sample = 1;
        while (bounds.outWidth / (sample * 2) >= targetWidth) sample *= 2;
        BitmapFactory.Options opts = new BitmapFactory.Options();
        opts.inSampleSize = sample;
        opts.inPreferredConfig = config;
        try {
            return BitmapFactory.decodeFile(file.getPath(), opts);
        } catch (OutOfMemoryError e) {
            return null;
        }
    }

    private Shots() {}
}
