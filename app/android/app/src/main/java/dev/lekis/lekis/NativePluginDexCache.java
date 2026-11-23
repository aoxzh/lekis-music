package dev.lekis.lekis;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Enumeration;
import java.util.HashSet;
import java.util.Set;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/** Snapshot a plugin's DEX into private, immutable, content-addressed dynamic code. */
final class NativePluginDexCache {
    private static final long MAX_DEX_BYTES = 128L * 1024 * 1024;

    static File snapshot(File source, File cache) throws IOException {
        if ((!cache.isDirectory() && !cache.mkdirs()) || Files.isSymbolicLink(cache.toPath())) {
            throw new IOException("Cannot create private native plugin code cache");
        }
        File temporary = File.createTempFile(".dex-", ".tmp", cache);
        try {
            MessageDigest digest = sha256();
            try (FileInputStream input = new FileInputStream(source);
                 FileOutputStream output = new FileOutputStream(temporary)) {
                // Android 14: mark dynamic code read-only immediately after opening it,
                // before writing through this already-open descriptor.
                if (!temporary.setReadOnly()) throw new IOException("Cannot make DEX read-only");
                byte[] buffer = new byte[64 * 1024];
                long copied = 0;
                int count;
                while ((count = input.read(buffer)) != -1) {
                    copied += count;
                    if (copied > MAX_DEX_BYTES) throw new IOException("DEX exceeds 128 MiB");
                    digest.update(buffer, 0, count);
                    output.write(buffer, 0, count);
                }
                if (copied == 0) throw new IOException("DEX is empty");
                output.getFD().sync();
            }
            boolean container = source.getName().endsWith(".jar");
            if (container) validateContainer(temporary);
            String hash = hex(digest.digest());
            File target = new File(cache, hash + (container ? ".jar" : ".dex"));
            if (target.exists()) {
                // Never trust a stale or writable cache entry just because its name matches.
                if (Files.isSymbolicLink(target.toPath()) || !hash.equals(hash(target))) {
                    throw new IOException("Native DEX cache integrity check failed");
                }
                if (!target.setReadOnly()) throw new IOException("Cannot make cached DEX read-only");
            } else {
                Files.move(temporary.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE);
            }
            return target;
        } finally {
            Files.deleteIfExists(temporary.toPath());
        }
    }

    private static void validateContainer(File file) throws IOException {
        // This is a DEX container, not a Java-class JAR. Do not unpack it into the filesystem.
        Set<String> names = new HashSet<>();
        long bytes = 0;
        byte[] buffer = new byte[64 * 1024];
        try (ZipFile archive = new ZipFile(file)) {
            Enumeration<? extends ZipEntry> entries = archive.entries();
            while (entries.hasMoreElements()) {
                ZipEntry entry = entries.nextElement();
                String name = entry.getName();
                if (names.size() >= 10_000 || !name.matches("classes(?:[2-9][0-9]*|1[0-9]+)?\\.dex") || !names.add(name)) {
                    throw new IOException("DEX container must contain only unique classes*.dex entries");
                }
                if (entry.getSize() == 0 || entry.getSize() > MAX_DEX_BYTES) {
                    throw new IOException("Invalid DEX container entry size");
                }
                try (java.io.InputStream input = archive.getInputStream(entry)) {
                    int count;
                    while ((count = input.read(buffer)) != -1) {
                        bytes += count;
                        if (bytes > MAX_DEX_BYTES) throw new IOException("DEX container expands beyond 128 MiB");
                    }
                }
            }
        }
        if (!names.contains("classes.dex")) throw new IOException("DEX container has no classes.dex");
    }

    private static String hash(File file) throws IOException {
        MessageDigest digest = sha256();
        try (FileInputStream input = new FileInputStream(file)) {
            byte[] buffer = new byte[64 * 1024];
            long bytes = 0;
            int count;
            while ((count = input.read(buffer)) != -1) {
                bytes += count;
                if (bytes > MAX_DEX_BYTES) throw new IOException("Cached DEX exceeds size limit");
                digest.update(buffer, 0, count);
            }
        }
        return hex(digest.digest());
    }

    private static MessageDigest sha256() {
        try { return MessageDigest.getInstance("SHA-256"); }
        catch (NoSuchAlgorithmException impossible) { throw new AssertionError(impossible); }
    }

    private static String hex(byte[] bytes) {
        StringBuilder result = new StringBuilder(64);
        for (byte value : bytes) result.append(String.format(java.util.Locale.ROOT, "%02x", value & 0xff));
        return result.toString();
    }
}
