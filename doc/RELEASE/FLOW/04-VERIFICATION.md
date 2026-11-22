# A10 Release Verification

The A10 build workflow runs Python unit tests before its long source build, then validates the produced ROM and the files named in pack-audit-intent.json. Any failed assertion exits nonzero and prevents artifact upload. The publish workflow repeats SHA256SUMS verification on the artifact downloaded from the successful tag run.

Local ROM generator tests:

```sh
python3 -m unittest discover -s rom -p 'test_*.py' -v
```

The audit-intent test checks romKey, versionPointer, minAppVersionCode, resident tar entries, and each listed file's exact bytes and SHA-256. Negative tests reject invalid pointers and a missing minimum app version.

Full build verification also checks the prepared manifest, rebuilds the A10 runtime closure, runs pack-rom.py --verify-only on the full package, asserts the placeholder contains only versebox_properties.yaml, and verifies that the resident tar exists. The release gate checks that each audit-intent file is present and matches its recorded byte count and hash before publishing.

Actions success is the CI gate. A local test pass does not establish that the Ubuntu runner completed the 300-minute source build or that a tagged Release was published. The A10 CI was edited in this workspace but has not been pushed or run on GitHub in this session.
