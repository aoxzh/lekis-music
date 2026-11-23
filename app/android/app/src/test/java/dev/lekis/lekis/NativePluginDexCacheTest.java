package dev.lekis.lekis;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.attribute.PosixFilePermission;
import java.util.Set;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;
import static org.junit.Assert.*;

public class NativePluginDexCacheTest {
    @Rule public TemporaryFolder temporary = new TemporaryFolder();

    @Test public void contentChangesProduceNewImmutableSnapshots() throws Exception {
        File source = temporary.newFile("classes.dex");
        File cache = temporary.newFolder("code-cache");
        byte[] firstBytes = "first plugin DEX snapshot".getBytes(StandardCharsets.UTF_8);
        Files.write(source.toPath(), firstBytes);
        File first = NativePluginDexCache.snapshot(source, cache);
        assertTrue(first.getName().matches("[0-9a-f]{64}\\.dex"));
        assertArrayEquals(firstBytes, Files.readAllBytes(first.toPath()));
        assertEquals(first, NativePluginDexCache.snapshot(source, cache));
        Files.write(source.toPath(), "changed plugin".getBytes(StandardCharsets.UTF_8));
        File second = NativePluginDexCache.snapshot(source, cache);
        assertNotEquals(first, second);
        assertArrayEquals(firstBytes, Files.readAllBytes(first.toPath()));
        Set<PosixFilePermission> permissions = Files.getPosixFilePermissions(first.toPath());
        assertFalse(permissions.contains(PosixFilePermission.OWNER_WRITE));
        assertFalse(permissions.contains(PosixFilePermission.GROUP_WRITE));
        assertFalse(permissions.contains(PosixFilePermission.OTHERS_WRITE));
        assertEquals(2, cache.list().length);
    }

    @Test public void corruptedOrSymlinkedCacheEntriesAreNeverLoaded() throws Exception {
        File source = temporary.newFile("classes.dex");
        File cache = temporary.newFolder("cache");
        Files.write(source.toPath(), new byte[] {1, 2, 3});
        File entry = NativePluginDexCache.snapshot(source, cache);
        assertTrue(entry.setWritable(true, true));
        Files.write(entry.toPath(), new byte[] {9, 8, 7});
        try { NativePluginDexCache.snapshot(source, cache); fail("must reject corruption"); }
        catch (java.io.IOException expected) { assertTrue(expected.getMessage().contains("integrity")); }
        Files.delete(entry.toPath());
        Files.createSymbolicLink(entry.toPath(), source.toPath());
        try { NativePluginDexCache.snapshot(source, cache); fail("must reject symlinks"); }
        catch (java.io.IOException expected) { assertTrue(expected.getMessage().contains("integrity")); }
        assertEquals(1, cache.list().length);
    }

    @Test public void emptyDexDoesNotLeavePartialFiles() throws Exception {
        File source = temporary.newFile("empty.dex");
        File cache = temporary.newFolder("cache");
        try { NativePluginDexCache.snapshot(source, cache); fail("must reject empty DEX"); }
        catch (java.io.IOException expected) { assertTrue(expected.getMessage().contains("empty")); }
        assertEquals(0, cache.list().length);
    }

    @Test public void multidexContainersKeepTheirExtensionAndRejectOtherEntries() throws Exception {
        File source = temporary.newFile("plugin.jar");
        File cache = temporary.newFolder("jar-cache");
        writeContainer(source, "classes.dex", "classes2.dex");
        File result = NativePluginDexCache.snapshot(source, cache);
        assertTrue(result.getName().matches("[0-9a-f]{64}\\.jar"));
        assertArrayEquals(Files.readAllBytes(source.toPath()), Files.readAllBytes(result.toPath()));
        for (String bad : new String[] {"../classes.dex", "/classes.dex", "folder/classes.dex", "classes1.dex", "META-INF/MANIFEST.MF"}) {
            writeContainer(source, "classes.dex", bad);
            try { NativePluginDexCache.snapshot(source, cache); fail(bad); }
            catch (java.io.IOException expected) { assertTrue(expected.getMessage().contains("classes*.dex")); }
        }
        writeContainer(source, "classes2.dex");
        try { NativePluginDexCache.snapshot(source, cache); fail("must require primary DEX"); }
        catch (java.io.IOException expected) { assertTrue(expected.getMessage().contains("no classes.dex")); }
        assertEquals(1, cache.list().length);
    }

    private static void writeContainer(File file, String... names) throws Exception {
        try (ZipOutputStream output = new ZipOutputStream(Files.newOutputStream(file.toPath()))) {
            for (String name : names) {
                output.putNextEntry(new ZipEntry(name));
                output.write(new byte[] {1, 2, 3});
                output.closeEntry();
            }
        }
    }

    @Test public void compressedMultidexCannotBypassTheExpandedSizeLimit() throws Exception {
        File source = temporary.newFile("expanded.jar");
        File cache = temporary.newFolder("expanded-cache");
        byte[] zeroes = new byte[1024 * 1024];
        try (ZipOutputStream output = new ZipOutputStream(Files.newOutputStream(source.toPath()))) {
            for (int index = 0; index < 2; index++) {
                output.putNextEntry(new ZipEntry(index == 0 ? "classes.dex" : "classes2.dex"));
                for (int mib = 0; mib < 64 + index; mib++) output.write(zeroes);
                output.closeEntry();
            }
        }
        assertTrue(source.length() < 1024 * 1024);
        try { NativePluginDexCache.snapshot(source, cache); fail("must bound total uncompressed DEX bytes"); }
        catch (java.io.IOException expected) { assertTrue(expected.getMessage().contains("128 MiB")); }
        assertEquals(0, cache.list().length);
    }
}
