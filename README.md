# RevancedYT

Automated ReVanced build pipeline for:
- YouTube
- YouTube Music

The project builds patched APKs, Magisk module ZIPs, no-root APK variants, and update JSON files.

## Scripts

- `revanced.sh`: main orchestration entrypoint
- `revanced-common.sh`: shared helper functions used by `revanced.sh`

## Local Run

Required environment variables:
- `GITHUB_TOKEN`
- `KEYSTORE_PASSWORD`

Run release flow:

```bash
./revanced.sh
```

Run test flow (no upload by default):

```bash
./revanced.sh test
```

Useful toggles:
- `SKIP_UPLOAD=true` to skip release creation/upload
- `FAST_BUILD=true` to speed up Gradle builds (`-x lint`)

## GitHub Actions

- Test workflow: `.github/workflows/test.yml`
	- runs `./revanced.sh test`
	- uses Gradle cache
	- sets `SKIP_UPLOAD=true` and `FAST_BUILD=true`

- Release workflow: `.github/workflows/revanced.yml`
	- runs `./revanced.sh`
	- scheduled with cron `30 0 * * 1,5` (UTC)
	- uses Gradle cache

## Notes

- ReVanced tools are fetched from upstream and built from source during the run.
- Logs are written to `.yt_build.log`.
- On failure, the script prints the tail of the build log automatically.

All credits to the ReVanced team.
