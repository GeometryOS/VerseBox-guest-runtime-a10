package io.a10vm.guest;

import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;
import java.lang.reflect.Method;

// The image ships gatekeeperd and its HAL, but this host never runs guest init, so neither
// starts and LockSettingsService dereferences a null IGateKeeperService once the device
// reports provisioning complete. A10 already answers other framework hooks the same way.
final class GuestGatekeeperStub {
    static final String SERVICE = "android.service.gatekeeper.IGateKeeperService";

    private static boolean available(Method check) throws Exception {
        return check.invoke(null, SERVICE) != null;
    }

    static void register() throws Exception {
        Class<?> manager = Class.forName("android.os.ServiceManager");
        Method check = manager.getMethod("checkService", String.class);
        if (available(check)) return;
        Binder endpoint = new Binder() {
            @Override protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) {
                if (data != null) data.enforceInterface(SERVICE);
                if (reply != null) reply.writeNoException();
                return true;
            }
        };
        endpoint.attachInterface(null, SERVICE);
        manager.getMethod("addService", String.class, IBinder.class)
                .invoke(null, SERVICE, endpoint);
        System.out.println("guest_gatekeeper_stub=1");
    }
}
