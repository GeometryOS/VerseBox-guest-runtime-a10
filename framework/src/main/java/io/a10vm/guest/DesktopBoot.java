package io.a10vm.guest;

import android.os.Build;
import java.lang.reflect.InvocationTargetException;

public final class DesktopBoot {
    public static void main(String[] args) throws Throwable {
        if (Build.VERSION.SDK_INT != 29) throw new AssertionError("Wrong guest SDK");
        System.out.println("desktop_guest_sdk=" + Build.VERSION.SDK_INT);
        ProcessEvidence.report("desktop");
        GuestApplication.configureRuntime(29);
        FlattenedApex.register();
        DesktopProcesses.start();
        GuestMemory.start();
        PrivateVolumes.register();
        PrivateKeyStore.register();
        // Registering an extra Binder endpoint before SystemServer starts is what separates the
        // rebuilt DEX from the shipped one; with the shipped a10binder transport it leaves the
        // broker link refused (errno 111) and later transacts fail with EBADF. Keep it opt-in
        // until the transport handles an extra endpoint across boot.
        if ("1".equals(System.getenv("A10VM_CREDENTIAL_STUB")))
            GuestCredentialCapabilities.register();
        GuestGatekeeperStub.register();
        GuestNetworks.register();
        GuestConnectivity.start();
        GuestCapabilities.configure();
        GuestSetup.start();
        try {
            Class.forName("com.android.server.SystemServer").getMethod("main", String[].class)
                    .invoke(null, (Object) new String[0]);
        } catch (InvocationTargetException failure) {
            throw failure.getCause();
        }
    }
}
