package dev.lekis.lekis;

import org.junit.Test;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import static org.junit.Assert.*;

public class NativePluginRunnerTest {
    @Test public void timeoutKeepsThePermitUntilWorkActuallyReturns() throws Exception {
        NativePluginRunner runner = new NativePluginRunner();
        CountDownLatch started = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        try {
            runner.run(() -> { started.countDown(); release.await(); return "late"; }, 50);
            fail("must time out");
        } catch (NativePluginRunner.Failure error) { assertEquals("timeout", error.code); }
        assertTrue(started.await(1, TimeUnit.SECONDS));
        try {
            runner.run(() -> { fail("must never queue another operation"); return "bad"; }, 100);
            fail("must report busy while timed-out code still executes");
        } catch (NativePluginRunner.Failure error) { assertEquals("busy", error.code); }
        finally { release.countDown(); }
        assertEventuallyAvailable(runner);
    }

    @Test public void interruptingTheCallerDoesNotInterruptOrUncountTheWorker() throws Exception {
        NativePluginRunner runner = new NativePluginRunner();
        CountDownLatch started = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        AtomicReference<Throwable> failure = new AtomicReference<>();
        Thread caller = new Thread(() -> {
            try { runner.run(() -> { started.countDown(); release.await(); return "done"; }, 5_000); }
            catch (Throwable error) { failure.set(error); }
        });
        caller.start();
        assertTrue(started.await(1, TimeUnit.SECONDS));
        caller.interrupt();
        caller.join(1_000);
        assertFalse(caller.isAlive());
        assertTrue(failure.get() instanceof NativePluginRunner.Failure);
        assertEquals("cancelled", ((NativePluginRunner.Failure) failure.get()).code);
        try { runner.run(() -> "bad", 100); fail("worker must remain counted"); }
        catch (NativePluginRunner.Failure error) { assertEquals("busy", error.code); }
        finally { release.countDown(); }
        assertEventuallyAvailable(runner);
    }

    @Test public void pluginExceptionsReleaseThePermit() throws Exception {
        NativePluginRunner runner = new NativePluginRunner();
        try { runner.run(() -> { throw new IllegalArgumentException("plugin error"); }, 1_000); fail(); }
        catch (IllegalArgumentException expected) { assertEquals("plugin error", expected.getMessage()); }
        assertEquals("next", runner.run(() -> "next", 1_000));
    }

    private static void assertEventuallyAvailable(NativePluginRunner runner) throws Exception {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
        while (System.nanoTime() < deadline) {
            try { assertEquals("next", runner.run(() -> "next", 1_000)); return; }
            catch (NativePluginRunner.Failure error) {
                if (!error.code.equals("busy")) throw error;
                Thread.sleep(5);
            }
        }
        fail("worker did not release its permit after returning");
    }
}
