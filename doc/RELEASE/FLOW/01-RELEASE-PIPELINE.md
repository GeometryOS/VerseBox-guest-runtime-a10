# A10 Release Pipeline

The build workflow proves the selected A10 source can produce prepared data, a ROM package, APK resident libraries, and a valid audit intent. The publish workflow only consumes the artifact from a successful tag build and must not rebuild different bytes.

```mermaid
flowchart TD
    A[Push, pull request, or manual build] --> B[Run rom Python unit tests]
    B --> C[Install pinned JDK and Android SDK tools]
    C --> D[Fetch image and build A10 runtime sources]
    D --> E[Generate prepared and versioned ROM directory]
    E --> F[Verify full/minimal ZIP and resident tar]
    F --> G[Verify pack-audit-intent files and hashes]
    G --> H[Upload runtime artifact and SHA256SUMS]
    H --> I{Tag build?}
    I -- No --> J[Build workflow ends]
    I -- Yes --> K[Release workflow checks successful run and tag]
    K --> L[Download exact run artifact]
    L --> M[Recheck SHA256SUMS and ROM package]
    M --> N[Build release title/body and update release index]
    N --> O[Publish A10 Release]
```

The workflow runner is Ubuntu 24.04. Source preparation and runtime generation remain inside guest-runtime-a10. The app repository's Gradle build does not produce any A10 ROM payload.

Current limitations: the tag release workflow still carries the existing A10 runtime tar in addition to ROM assets. The app-facing Release asset minimization described by root app docs applies to the app repository, not this runtime repository.
