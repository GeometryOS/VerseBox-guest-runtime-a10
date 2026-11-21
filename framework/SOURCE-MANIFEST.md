# A10 Java source closure

This directory contains the A10-owned source closure for the two check DEX files.
The files were copied byte-for-byte from the legacy Android 10 runtime; the legacy tree remains unchanged.

## Current mapping

| Input | Source rule | Count |
| --- | --- | ---: |
| `runtime-check.dex` | `guest-runtime/check/RuntimeCheck.java`, `DirectoryCheck.java`, `ProcessEvidence.java` | 3 |
| `framework-check.dex` | A10-owned copies of the selected `guest-runtime/check/*.java` files plus `guest-runtime/test/AppRuntimeOptionsCheck.java` | 51 + 1 |
| Framework adapters | A10-owned copies of `guest-runtime/framework-adapters/*.java` | 2 |

The copied source count is 54 files. Each copied file has the same SHA-256 as its legacy source.
The source package remains `io.a10vm.guest` because the class names are part of the guest runtime contract.

## Current gaps

The existing `framework-check.dex` also contains top-level descriptors named `ApplicationCodePaths` and
`GuestNativePaths`. No corresponding source declaration exists under `guest-runtime/`, and neither class
appears in the checked-in source archives. They are not replaced with a binary. The DEX generator must either
reproduce their source from an identified historical input or deliberately exclude them from a newly generated
A10 DEX after checking every call site.

The bridge jar is a separate source investigation. Its six classes are not part of this Java closure:
`BridgeMain`, `RfbServer`, `RfbServer$Input`, `RfbServer$Screen`, `AndroidInput`, and `AndroidScreen`.
