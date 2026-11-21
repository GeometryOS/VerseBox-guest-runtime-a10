# A10 Java source closure

This directory contains the A10-owned source closure for the two check DEX files.
The files were copied byte-for-byte from the legacy Android 10 runtime; the legacy tree remains unchanged.

## Current mapping

| Input | Source rule | Count |
| --- | --- | ---: |
| `runtime-check.dex` | `guest-runtime/check/RuntimeCheck.java`, `DirectoryCheck.java`, `ProcessEvidence.java` | 3 |
| `framework-check.dex` | A10-owned copies of the complete legacy `build-checks.sh` source list plus `guest-runtime/test/AppRuntimeOptionsCheck.java`; `ProcessEvidence.java` is shared into both DEX inputs | 75 source files |
| Framework adapters | A10-owned copies of `guest-runtime/framework-adapters/*.java` | 2 |

The A10 source tree contains 77 unique Java files: 74 from the legacy build-checks source list, 1 extra AppRuntimeOptionsCheck fixture, and 2 framework adapters. The framework DEX compiles 75 sources; runtime DEX compiles RuntimeCheck, DirectoryCheck and ProcessEvidence, with ProcessEvidence shared across both DEX inputs. All copied files have the same SHA-256 as their legacy source.
The source package remains `io.a10vm.guest` because the class names are part of the guest runtime contract.

## Legacy DEX residuals

The existing prepared `framework-check.dex` contains top-level descriptors named `ApplicationCodePaths` and
`GuestNativePaths`, but no corresponding source declaration exists in the legacy tree or source archives. A call-site
scan found no reference to `GuestNativePaths`; `ApplicationCodePathsCheck` references the existing
`io.a10vm.framework.PackageCodePaths` adapter, not an `ApplicationCodePaths` class. The A10 source-generated DEX
therefore excludes these two stale descriptors instead of replacing them with a binary or invented source.

The legacy prepared tree also contained a bridge jar with six classes (`BridgeMain`, `RfbServer`, `RfbServer$Input`, `RfbServer$Screen`, `AndroidInput`, `AndroidScreen`). Source and host consumer searches found no current call path: FrameworkSession explicitly starts HALs, SurfaceFlinger, DesktopBoot and DesktopInput, and does not run guest init. The bridge jar and its init rc are therefore excluded from the new A10 inventory; existing prepared trees and previously built ROMs are unchanged.
