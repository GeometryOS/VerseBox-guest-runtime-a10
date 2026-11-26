# A10 Version Sources

Version facts have one source each. The output directory, ZIP file names, ROM identity, resident tar name, and audit intent are generated from the selected ROM metadata and packed ROM properties.

| Fact | Source | Consumer |
| --- | --- | --- |
| ROM id | rom/rom.properties.yaml: id | ROM package and romKey |
| Default ROM version | rom/rom.properties.yaml: defaultRomVersion | build-a10.sh output directory and packer default |
| Minimum app version | rom/rom.properties.yaml: minAppVersionCode | pack-audit-intent.json, consumed against app versionCode |
| Payload file sizes and payload hash | packaged payload | versebox_properties.yaml and pack summary |
| Distribution file names, sizes, hashes | completed ZIP/min ZIP/resident tar | pack-audit-intent.json and SHA256SUMS |

The intent carries no selection policy. maxcv is an app-side VERSION value; the ROM only publishes minAppVersionCode as its compatibility floor. An app may select a release when its versionCode is at least that floor, and the app never predicts or caps future ROM versions.

A ROM repository setting does not configure which source the app uses. The app dotenv example and local configuration select local dist or a GitHub repository, and choose a fixed version or maxcv independently for each ROM id.
