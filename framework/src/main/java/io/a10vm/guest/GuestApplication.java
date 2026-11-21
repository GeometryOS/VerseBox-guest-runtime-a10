package io.a10vm.guest;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.Arrays;

public final class GuestApplication {
    public static void main(String[] args) throws Throwable {
        String started = System.getenv("A10VM_APPLICATION_START_NS");
        if (started != null)
            System.out.println("guest_application_entry_ms=" +
                    (android.os.SystemClock.elapsedRealtimeNanos() - Long.parseLong(started)) / 1000000);
        String parent = System.getenv("A10VM_APPLICATION_PARENT_PID");
        if (parent != null) {
            // PDEATHSIG still kills this process the moment the container dies. The numeric
            // comparison only rejects a process that was already orphaned: A10 children are
            // reparented to the host app process (a child subreaper, pid 6591 here), so the
            // recorded container pid legitimately differs from getppid() at entry.
            android.system.Os.prctl(1, android.system.OsConstants.SIGKILL, 0, 0, 0);
            if (android.system.Os.getppid() == 1)
                throw new IllegalStateException("Guest application parent exited");
        }
        ProcessEvidence.report("application");
        BootNativeLibraries.load();
        configureRuntime(Integer.parseInt(args[0]));
        if (args[1].equals("android.app.ActivityThread")) PackageQueryClient.install();
        GuestWebView.reserve();
        if (started != null)
            System.out.println("guest_application_ready_ms=" +
                    (android.os.SystemClock.elapsedRealtimeNanos() - Long.parseLong(started)) / 1000000);
        if ("software".equals(System.getenv("A10VM_APP_CANVAS"))) {
            Class.forName("android.view.ThreadedRenderer").getMethod("disable", boolean.class)
                    .invoke(null, true);
            System.out.println("application_canvas=software");
        }
        if (args[1].equals("android.webkit.WebViewLibraryLoader$RelroFileCreator")) {
            android.os.Looper.prepareMainLooper();
            Class.forName("android.app.ActivityThread").getMethod("systemMain").invoke(null);
        }
        try {
            Method main = Class.forName(args[1]).getDeclaredMethod("main", String[].class);
            main.setAccessible(true);
            main.invoke(null, (Object) Arrays.copyOfRange(args, 2, args.length));
        } catch (InvocationTargetException error) { throw error.getCause(); }
    }

    static void configureRuntime(int sdk) throws Exception {
        Class<?> vm = Class.forName("dalvik.system.VMRuntime");
        Object runtime = vm.getMethod("getRuntime").invoke(null);
        vm.getMethod("setTargetSdkVersion", int.class).invoke(runtime, sdk);
        Class.forName("android.graphics.Typeface");
        Class.forName("android.security.keystore.AndroidKeyStoreProvider").getMethod("install").invoke(null);
    }
}
