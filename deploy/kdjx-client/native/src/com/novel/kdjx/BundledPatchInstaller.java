package com.novel.kdjx;

import android.content.Context;
import android.content.SharedPreferences;
import android.content.res.AssetManager;
import android.util.Log;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.Charset;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.regex.Pattern;

/** Installs the signed APK's cumulative hot-update snapshot before Cocos starts. */
final class BundledPatchInstaller {
    private static final String TAG = "KdjxBundledPatch";
    private static final Charset UTF_8 = Charset.forName("UTF-8");
    private static final String ASSET_MANIFEST = "sakura-bootstrap/manifest.tsv";
    private static final String ASSET_FILE_PREFIX = "sakura-bootstrap/files/";
    private static final String MARKER_NAME = ".sakura-bundled-patch";
    private static final String COCOS_PREFERENCES = "Cocos2dxPrefsFile";
    // Native hashes the business keys before calling Cocos UserDefault.
    private static final String APP_VERSION_KEY =
            "8e58ea257ca802d186cba7f07d287f00";
    private static final String PATCH_VERSION_KEY =
            "96773f3f45bb6396332b079593367c71";
    private static final String APP_VERSION = "2.1.0.0";
    private static final String TEMP_SUFFIX = ".sakura.tmp";
    private static final Pattern SAFE_NAME =
            Pattern.compile("[A-Za-z0-9._@()/-]+");
    private static final Pattern MD5 = Pattern.compile("[a-f0-9]{32}");
    private static final Pattern REVISION = Pattern.compile("[a-f0-9]{40}");
    private static final int BUFFER_SIZE = 64 * 1024;

    private BundledPatchInstaller() {}

    static void install(Context context) {
        long startedAt = System.currentTimeMillis();
        try {
            InstallResult result = installChecked(context);
            Log.i(
                    TAG,
                    "patch=" + result.patch
                            + " files=" + result.files
                            + " bytes=" + result.bytes
                            + " skipped=" + result.skipped
                            + " elapsedMs=" + (System.currentTimeMillis() - startedAt));
        } catch (Exception error) {
            Log.e(TAG, "Bundled patch installation failed", error);
            throw new IllegalStateException("bundled_patch_install_failed", error);
        }
    }

    private static InstallResult installChecked(Context context) throws Exception {
        AssetManager assets = context.getAssets();
        InputStream manifestInput;
        try {
            manifestInput = assets.open(
                    ASSET_MANIFEST,
                    AssetManager.ACCESS_STREAMING);
        } catch (FileNotFoundException missing) {
            return new InstallResult("none", 0, 0L, true);
        }
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(
                manifestInput, UTF_8))) {
            String header = reader.readLine();
            Header parsedHeader = parseHeader(header);
            List<Entry> entries = readEntries(reader, parsedHeader);
            int targetPatch = Integer.parseInt(parsedHeader.patch);
            SharedPreferences preferences = context.getSharedPreferences(
                    COCOS_PREFERENCES,
                    Context.MODE_PRIVATE);
            int currentPatch = preferenceInteger(
                    preferences,
                    PATCH_VERSION_KEY);
            if (currentPatch > targetPatch) {
                return new InstallResult(
                        parsedHeader.patch,
                        parsedHeader.files,
                        parsedHeader.bytes,
                        true);
            }

            File storageRoot = new File(context.getFilesDir(), "patch");
            ensureDirectory(storageRoot);
            File patchRoot = new File(storageRoot, parsedHeader.patch);
            File marker = new File(
                    storageRoot,
                    MARKER_NAME + "-" + parsedHeader.patch);
            if (patchRoot.isDirectory()
                    && header.equals(readFirstLine(marker))) {
                synchronizePatchState(preferences, targetPatch);
                return new InstallResult(
                        parsedHeader.patch,
                        parsedHeader.files,
                        parsedHeader.bytes,
                        true);
            }

            if (!directoryMatches(patchRoot, entries)) {
                File staging = new File(
                        storageRoot,
                        ".preload-" + parsedHeader.patch + ".tmp");
                deleteRecursively(staging);
                ensureDirectory(staging);
                String stagingPath = staging.getCanonicalPath() + File.separator;
                for (Entry entry : entries) {
                    File target = new File(staging, entry.name);
                    if (!target.getCanonicalPath().startsWith(stagingPath)) {
                        throw new IOException("bundled_patch_path_invalid");
                    }
                    copyVerified(assets, target, entry);
                }
                publishDirectory(staging, patchRoot);
            }
            writeMarker(marker, header);
            synchronizePatchState(preferences, targetPatch);
            return new InstallResult(
                    parsedHeader.patch,
                    parsedHeader.files,
                    parsedHeader.bytes,
                    false);
        }
    }

    private static List<Entry> readEntries(
            BufferedReader reader,
            Header header) throws IOException {
        List<Entry> entries = new ArrayList<Entry>(header.files);
        Set<String> names = new HashSet<String>();
        String previousName = "";
        long totalBytes = 0L;
        String line;
        while ((line = reader.readLine()) != null) {
            Entry entry = parseEntry(line);
            if (!names.add(entry.name)
                    || (previousName.length() > 0
                    && entry.name.compareTo(previousName) <= 0)) {
                throw new IOException("bundled_patch_manifest_order_invalid");
            }
            previousName = entry.name;
            entries.add(entry);
            totalBytes = checkedAdd(totalBytes, entry.size);
        }
        if (entries.size() != header.files || totalBytes != header.bytes) {
            throw new IOException("bundled_patch_manifest_totals_invalid");
        }
        if (!names.contains("version.diff")
                || !names.contains("res/version.plist")) {
            throw new IOException("bundled_patch_runtime_metadata_missing");
        }
        return entries;
    }

    private static Header parseHeader(String line) throws IOException {
        if (line == null) throw new IOException("bundled_patch_manifest_empty");
        String[] fields = line.split("\t", -1);
        if (fields.length != 6
                || !"sakura-bundled-patch".equals(fields[0])
                || !"1".equals(fields[1])
                || !isPositiveInteger(fields[2])
                || !REVISION.matcher(fields[3]).matches()
                || !isPositiveInteger(fields[4])
                || !isPositiveLong(fields[5])) {
            throw new IOException("bundled_patch_manifest_header_invalid");
        }
        return new Header(
                fields[2],
                Integer.parseInt(fields[4]),
                Long.parseLong(fields[5]));
    }

    private static Entry parseEntry(String line) throws IOException {
        String[] fields = line.split("\t", -1);
        if (fields.length != 3
                || !safeName(fields[0])
                || !isPositiveLong(fields[1])
                || !MD5.matcher(fields[2]).matches()) {
            throw new IOException("bundled_patch_manifest_entry_invalid");
        }
        return new Entry(fields[0], Long.parseLong(fields[1]), fields[2]);
    }

    private static boolean safeName(String name) {
        if (!SAFE_NAME.matcher(name).matches()
                || name.startsWith("/")
                || name.endsWith("/")
                || name.contains("//")) {
            return false;
        }
        for (String part : name.split("/", -1)) {
            if (part.length() == 0 || ".".equals(part) || "..".equals(part)) {
                return false;
            }
        }
        return true;
    }

    private static boolean isPositiveInteger(String value) {
        try {
            return value.matches("[1-9][0-9]{0,8}")
                    && Integer.parseInt(value) > 0;
        } catch (NumberFormatException ignored) {
            return false;
        }
    }

    private static boolean isPositiveLong(String value) {
        try {
            return value.matches("[1-9][0-9]{0,18}")
                    && Long.parseLong(value) > 0;
        } catch (NumberFormatException ignored) {
            return false;
        }
    }

    private static void ensureDirectory(File directory) throws IOException {
        if (directory.isDirectory()) return;
        if (!directory.mkdirs() && !directory.isDirectory()) {
            throw new IOException("bundled_patch_directory_unavailable");
        }
    }

    private static boolean matches(File file, long size, String expectedMd5)
            throws Exception {
        return file.isFile()
                && file.length() == size
                && expectedMd5.equals(digest(file));
    }

    private static boolean directoryMatches(File root, List<Entry> entries)
            throws Exception {
        if (!root.isDirectory()) return false;
        String rootPath = root.getCanonicalPath() + File.separator;
        for (Entry entry : entries) {
            File file = new File(root, entry.name);
            if (!file.getCanonicalPath().startsWith(rootPath)
                    || !matches(file, entry.size, entry.md5)) {
                return false;
            }
        }
        return true;
    }

    private static String digest(File file) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("MD5");
        byte[] buffer = new byte[BUFFER_SIZE];
        try (InputStream input = new FileInputStream(file)) {
            int count;
            while ((count = input.read(buffer)) != -1) {
                digest.update(buffer, 0, count);
            }
        }
        return hex(digest.digest());
    }

    private static void copyVerified(
            AssetManager assets,
            File target,
            Entry entry) throws Exception {
        File parent = target.getParentFile();
        if (parent == null) throw new IOException("bundled_patch_parent_invalid");
        ensureDirectory(parent);
        File temporary = new File(parent, target.getName() + TEMP_SUFFIX);
        if (temporary.exists() && !temporary.delete()) {
            throw new IOException("bundled_patch_temporary_unavailable");
        }

        MessageDigest digest = MessageDigest.getInstance("MD5");
        long written = 0L;
        byte[] buffer = new byte[BUFFER_SIZE];
        try {
            try (InputStream input = assets.open(
                    ASSET_FILE_PREFIX + entry.name,
                    AssetManager.ACCESS_STREAMING);
                 FileOutputStream output = new FileOutputStream(temporary)) {
                int count;
                while ((count = input.read(buffer)) != -1) {
                    output.write(buffer, 0, count);
                    digest.update(buffer, 0, count);
                    written = checkedAdd(written, count);
                }
                output.flush();
            }
            if (written != entry.size || !entry.md5.equals(hex(digest.digest()))) {
                throw new IOException("bundled_patch_asset_digest_mismatch");
            }
            if (target.exists() && !target.delete()) {
                throw new IOException("bundled_patch_target_unavailable");
            }
            if (!temporary.renameTo(target)) {
                throw new IOException("bundled_patch_commit_failed");
            }
        } finally {
            if (temporary.exists() && !temporary.delete()) {
                Log.w(TAG, "Could not remove temporary patch file");
            }
        }
    }

    private static String readFirstLine(File file) throws IOException {
        if (!file.isFile() || file.length() > 512L) return "";
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(
                new FileInputStream(file), UTF_8))) {
            String line = reader.readLine();
            return line == null ? "" : line;
        }
    }

    private static void writeMarker(File marker, String header) throws IOException {
        File temporary = new File(marker.getParentFile(), marker.getName() + TEMP_SUFFIX);
        if (temporary.exists() && !temporary.delete()) {
            throw new IOException("bundled_patch_marker_unavailable");
        }
        try {
            try (FileOutputStream output = new FileOutputStream(temporary)) {
                output.write((header + "\n").getBytes(UTF_8));
                output.flush();
                output.getFD().sync();
            }
            if (marker.exists() && !marker.delete()) {
                throw new IOException("bundled_patch_marker_unavailable");
            }
            if (!temporary.renameTo(marker)) {
                throw new IOException("bundled_patch_marker_commit_failed");
            }
        } finally {
            if (temporary.exists() && !temporary.delete()) {
                Log.w(TAG, "Could not remove temporary patch marker");
            }
        }
    }

    private static void publishDirectory(File staging, File target)
            throws IOException {
        if (target.exists()) deleteRecursively(target);
        if (!staging.renameTo(target)) {
            throw new IOException("bundled_patch_directory_commit_failed");
        }
    }

    private static void deleteRecursively(File path) throws IOException {
        if (!path.exists()) return;
        if (path.isDirectory()) {
            File[] children = path.listFiles();
            if (children == null) {
                throw new IOException("bundled_patch_directory_unreadable");
            }
            for (File child : children) deleteRecursively(child);
        }
        if (!path.delete() && path.exists()) {
            throw new IOException("bundled_patch_delete_failed");
        }
    }

    private static void synchronizePatchState(
            SharedPreferences preferences,
            int targetPatch) throws IOException {
        int current = preferenceInteger(preferences, PATCH_VERSION_KEY);
        if (current > targetPatch) return;
        if (!preferences.edit()
                .putString(APP_VERSION_KEY, APP_VERSION)
                .putInt(PATCH_VERSION_KEY, targetPatch)
                .commit()) {
            throw new IOException("bundled_patch_version_commit_failed");
        }
    }

    private static int preferenceInteger(
            SharedPreferences preferences,
            String key) {
        Object value = preferences.getAll().get(key);
        if (value instanceof Integer) return (Integer) value;
        if (value instanceof Float) return ((Float) value).intValue();
        if (value instanceof Boolean) return (Boolean) value ? 1 : 0;
        if (value instanceof String) {
            try {
                return Integer.parseInt((String) value);
            } catch (NumberFormatException ignored) {
                return 0;
            }
        }
        return 0;
    }

    private static String hex(byte[] value) {
        final char[] digits = "0123456789abcdef".toCharArray();
        char[] output = new char[value.length * 2];
        for (int index = 0; index < value.length; index++) {
            int current = value[index] & 0xff;
            output[index * 2] = digits[current >>> 4];
            output[index * 2 + 1] = digits[current & 0x0f];
        }
        return new String(output);
    }

    private static long checkedAdd(long left, long right) throws IOException {
        if (right < 0L || left > Long.MAX_VALUE - right) {
            throw new IOException("bundled_patch_size_overflow");
        }
        return left + right;
    }

    private static final class Header {
        final String patch;
        final int files;
        final long bytes;

        Header(String patch, int files, long bytes) {
            this.patch = patch;
            this.files = files;
            this.bytes = bytes;
        }
    }

    private static final class Entry {
        final String name;
        final long size;
        final String md5;

        Entry(String name, long size, String md5) {
            this.name = name;
            this.size = size;
            this.md5 = md5;
        }
    }

    private static final class InstallResult {
        final String patch;
        final int files;
        final long bytes;
        final boolean skipped;

        InstallResult(String patch, int files, long bytes, boolean skipped) {
            this.patch = patch;
            this.files = files;
            this.bytes = bytes;
            this.skipped = skipped;
        }
    }
}
