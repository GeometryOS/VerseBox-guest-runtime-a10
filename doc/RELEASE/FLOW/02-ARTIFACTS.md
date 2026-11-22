# A10 Release Artifacts

ROM outputs are isolated by ROM key: dist/<id>@<romVersion>/. With the current A10 properties, the ROM id is android10, the default ROM version is read from rom.properties.yaml, and different versions no longer overwrite the same resident tar or scatter into dist root.

| File | Purpose |
| --- | --- |
| versebox-<id>-<version>.zip | Complete guest ROM |
| versebox-<id>-<version>-min.zip | Placeholder package containing only versebox_properties.yaml |
| apk-resident-libs-<id>-<version>.tar | APK resident shared objects, stored flat with executable mode |
| pack-audit-intent.json | Generated app-facing version, compatibility, size, and SHA-256 manifest |

The audit intent includes schema, romKey, versionPointer, minAppVersionCode, packSeconds, and a files array. Each files entry records the final file name, exact byte size, and SHA-256. The audit intent does not hash itself. The full ZIP, minimal ZIP, and resident tar are hashed after generation.

A10 currently sets versionPointer to maxcv and minAppVersionCode to 105 in rom/rom.properties.yaml. Those values are inputs owned by the runtime maintainer. The packer copies them into the generated ROM metadata and audit intent; it does not infer a future app compatibility limit.
