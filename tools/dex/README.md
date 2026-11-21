# A10 services.jar patcher

PatchWifiRelay.java rewrites the Android 10 services.jar DEX with dexlib2. The source is copied byte-for-byte from the legacy guest-runtime/build-tools directory. The legacy tree is not part of this build.

The dependency is not currently available as a checked-in or local reproducible archive. The old script accepted A10VM_DEXLIB_JAR and defaulted to a Termux JADX all-in-one jar. That path is not a valid A10 CI input, so this tool is not wired into prepare-a10.py yet.

Before wiring it, add a pinned dexlib2 source/archive with its checksum, then compile the patcher in the A10 repository and verify the gate counts: gates=1 and callbacks=1. The input services.jar must come from the Redroid 10 rootfs; the output must be written to runtime/build/data before prepare consumes it.
