package dev.lekis.lekis;

import java.util.concurrent.Callable;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

/** One running native operation, including work that outlives its caller's timeout. */
final class NativePluginRunner {
    private final Semaphore available = new Semaphore(1);
    private final ExecutorService worker = Executors.newSingleThreadExecutor(task -> {
        Thread thread = new Thread(task, "lekis-native-plugin");
        thread.setDaemon(true);
        return thread;
    });

    static final class Failure extends Exception {
        private static final long serialVersionUID = 1L;
        final String code;
        Failure(String code, String message) {
            super(message);
            this.code = code;
        }
    }

    String run(Callable<String> operation, long timeoutMs) throws Exception {
        if (!available.tryAcquire()) {
            throw new Failure("busy", "A native plugin operation is still running");
        }
        Future<String> result;
        try {
            result = worker.submit(() -> {
                try {
                    return operation.call();
                } finally {
                    // The worker owns the permit. Timeout/interruption of get() never releases it.
                    available.release();
                }
            });
        } catch (RuntimeException failure) {
            available.release();
            throw failure;
        }
        try {
            return result.get(timeoutMs, TimeUnit.MILLISECONDS);
        } catch (TimeoutException failure) {
            // Interrupting arbitrary DEX code is not a reliable way to stop it. Keep it counted.
            throw new Failure("timeout", "Native plugin operation exceeded its deadline");
        } catch (InterruptedException failure) {
            Thread.currentThread().interrupt();
            throw new Failure("cancelled", "Native plugin caller was interrupted");
        } catch (ExecutionException failure) {
            Throwable cause = failure.getCause();
            if (cause instanceof Exception) throw (Exception) cause;
            throw new Failure("plugin", "Native plugin failed: " + cause.getClass().getSimpleName());
        }
    }
}
