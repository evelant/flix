package dev.flix.runtime;

import java.util.concurrent.locks.Condition;
import java.util.concurrent.locks.ReentrantLock;

/**
 * Portable reentrant-lock runtime support for the JVM backend.
 *
 * The contract is task-oriented: ownership is tracked by the current Flix task.
 * On the JVM today each portable Flix task runs on one Java thread, so thread identity
 * is the concrete owner token used here.
 */
public final class LockSupport {

    private LockSupport() {
    }

    public static Object newLock() {
        return new PortableLock();
    }

    public static void lock(Object lock) {
        ((PortableLock) lock).lock();
    }

    public static boolean tryLock(Object lock) {
        return ((PortableLock) lock).tryLock();
    }

    public static boolean unlock(Object lock) {
        return ((PortableLock) lock).unlock();
    }

    private static void awaitOrCancel(Condition condition) {
        try {
            condition.await();
        } catch (InterruptedException e) {
            throw CancellationWakeup.INSTANCE;
        }
    }

    private static final class PortableLock {
        private final ReentrantLock mutex = new ReentrantLock();
        private final Condition available = mutex.newCondition();
        private Thread owner = null;
        private int depth = 0;

        private void lock() {
            final Thread current = Thread.currentThread();
            mutex.lock();
            try {
                if (owner == current) {
                    depth += 1;
                    return;
                }

                while (owner != null) {
                    awaitOrCancel(available);
                }

                owner = current;
                depth = 1;
            } finally {
                mutex.unlock();
            }
        }

        private boolean tryLock() {
            final Thread current = Thread.currentThread();
            mutex.lock();
            try {
                if (owner == null) {
                    owner = current;
                    depth = 1;
                    return true;
                }
                if (owner == current) {
                    depth += 1;
                    return true;
                }
                return false;
            } finally {
                mutex.unlock();
            }
        }

        private boolean unlock() {
            final Thread current = Thread.currentThread();
            mutex.lock();
            try {
                if (owner != current || depth == 0) {
                    return false;
                }

                depth -= 1;
                if (depth == 0) {
                    owner = null;
                    available.signal();
                }
                return true;
            } finally {
                mutex.unlock();
            }
        }
    }
}
