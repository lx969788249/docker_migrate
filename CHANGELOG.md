# Changelog

## Unreleased

### Clearer errors when the old server cannot be reached

- Before the pre-flight check, the new server makes one quick connection to the old server. If the connection times out or is refused, it stops right away and says which port to open in the cloud security group or firewall (`ufw` / `firewall-cmd`), instead of retrying the download for several minutes.

### Fixes

- Keep the image's own entrypoint and command when the container did not change them. Images whose entrypoint has several parts (for example Uptime Kuma's `dumb-init -- extra/entrypoint.sh`) used to come back with part of the entrypoint moved into the command, which also pinned the command across image updates. Found by the new application tests.

### Tests

- Add `tests/apps/`: each run starts two independent simulated servers (Docker-in-Docker) and migrates a real application from one to the other: WordPress, Nextcloud, Gitea, Vaultwarden, Uptime Kuma, Halo, Memos, plus an unusual Compose setup (three `-f` files, a locally built image, profiles, an external network with a fixed range, and a standalone container). Each test writes data in the app on the old server, checks it on the new one, compares container settings on both servers, and checks that the old server is back to its original state.
- Test the new connection messages by blocking the port with a firewall rule on the simulated old server.
- Run these tests in a separate `apps` workflow on master, on pull requests, and once a week.

## 2.5.1

### Fixes found in a real two-server migration

- Restore Compose projects under their original project name. Projects started with `-p`, `COMPOSE_PROJECT_NAME` or a panel-chosen name used to be recreated under the directory name, so the restore waited for containers that never appeared, rolled back, and left the wrongly named containers behind.
- Create standalone networks before starting Compose projects. A Compose network picks the first free address range on its own, which could be the range a standalone network used on the source, and that network then failed to create.
- Generate the resolved Compose configuration with the original project name on the source as well.
- Keep Compose warnings (such as the obsolete `version` attribute) in the log instead of breaking the progress line.
- Show container names instead of IDs while analysing the selected containers.

## 2.5.0

### Pre-flight check

- Before downloading, the new server fetches a small encrypted migration plan from the same link (no extra copy-paste) and checks CPU type, disk space, port usage, network ranges, static IPs, existing containers and volumes, Compose availability, runtimes, devices and volume plugins.
- Problems are sorted by impact: harmless differences such as an older Docker version are only noted; problems that would make the migration fail stop and offer targeted choices (use a free port, enter a port, stop publishing it, recheck, replace or keep an existing container, let Docker pick a network range or IP, keep an existing volume, use another download directory); problems that cannot be worked around stop with an explanation.
- Compose port conflicts are never rewritten automatically; the user can fix the port and recheck, or skip the project and migrate the rest.
- The restore applies these choices and lists every adjustment in the final summary.
- Add `--check=URL` to run only the pre-flight check, `RESTORE_AUTO_RESOLVE=1` to accept recommended fixes without a terminal, and `RESTORE_SKIP_PREFLIGHT=1` to skip it.
- Restoring by hand from an extracted bundle runs the same check.

### Wording

- Rewrite rollback and error messages in plain language and rename restore steps (检查迁移包、备份已有服务).

## 2.4.0

### Output and progress

- Show the run as numbered steps (7 for backup, 8 for restore); each step takes one line that updates in place and ends with its result and duration.
- Progress bars show percentage, speed and remaining time for downloads, image save/load, data archives, encryption, decryption and extraction, using a built-in byte counter instead of the optional `pv`.
- When nothing moves for 30 seconds, the progress line says what the script is waiting for, so long steps are not mistaken for a hang.
- Warnings take one line and are listed again in the final summary together with per-step timings.
- All messages, including the per-container restore script, are in Chinese.

### Logging and diagnosis

- Every run writes a full log (environment, each step, every Docker command and its output) to `~/docker_migrate_logs`; it is deleted after a successful run and kept on failure.
- Keys from migration links and password-like environment values are hidden in logs.
- Docker command errors that were previously discarded are now recorded.
- Failures end with the failing step, a plain-language cause, a suggested fix, the log path and the last log lines; common Docker, network and disk errors are recognized.
- Add `--verbose` to show step details on screen and `--diagnose` to collect a redacted report for issues.
- Fix error output disappearing after the restore lock was released, which hid the final step result and any later error messages.

## 2.3.0

### Restore fidelity

- Recreate host system bind mounts (`/etc/localtime`, `/proc`, `/sys`, `/dev`, `/var/log`, and similar) without migrating or overwriting them; restores no longer fail on the `/etc/localtime` symlink.
- Back up the real data behind symlinked bind sources and recreate the link on the target.
- Fix restoring read-only bind mounts (`-v src:dst:ro`), which produced the invalid mount mode `ro,ro`.
- Restore only explicitly assigned static IPs; dynamically assigned addresses are no longer pinned on the target, where they could collide with other containers.
- Install `find` when missing (minimal images) and keep interrupted-restore summaries visible on bash 4.0/4.1.
- Restore standalone containers that share another container's network namespace: skip conflicting hostname, DNS, hosts and port options, restore dependencies first, and include the dependency automatically during backup.
- Keep the image's own healthcheck instead of rewriting exec-form checks to shell form, so images without `/bin/sh` pass health verification.
- Snapshot a container's writable layer only when it has real changes (or the image tag moved); other containers keep their original image name for normal upgrades. `DOCKER_MIGRATE_SNAPSHOT=always|never` overrides this.

### Removed

- Restores accept only encrypted links that carry the source digest, key, IV and HMAC; plaintext links from early versions, bundles without a checksum list, legacy network records and `RESTORE_ALLOW_UNVERIFIED` are no longer supported. Migration bundles exist only while the source script is serving them, so regenerate them with the current script.
- Remove unused helpers (`CYA`, `bundle_encrypt_file`, `verify_bundle_hmac`, `verify_archive_sha256`).

### Development

- Split the 6,800-line script into modules under `src/`; `./build.sh` assembles the single-file `docker_migrate_perfect.sh`, and CI rejects a release file that does not match `src/`.
- Generated `restore.sh` and per-container scripts now include the shared `src/lib/` functions instead of carrying their own copies (progress, checksums, manifest checks, system paths, container networks).

### Testing

- Add a real-world configuration fidelity test that migrates eight differently configured containers end to end and compares their `docker inspect` output.
- Run unit tests on bash 4.0, 4.2 and 4.4, Alpine, Debian 12 and Rocky Linux 8.
- Add a manual two-server test checklist in `docs/manual-vps-test.md`.

### Usability

- Support IPv6-only servers: bracket IPv6 hosts in links, serve downloads on IPv4 and IPv6, and warn instead of silently advertising `127.0.0.1`.
- Do not abort non-interactive `--backup` runs at the downtime prompt; ask for `--include` instead of failing at the container menu.
- Show which TCP port to open in the firewall or security group next to the download link.
- Check free disk space before encrypting and decrypting, and delete the plaintext bundle and the downloaded ciphertext as soon as they are no longer needed.

## 2.0.0

### Reliability

- Fail the backup when an image, named volume, bind mount, Compose file, or network definition cannot be captured.
- Preserve command exit codes and return a non-zero status when any restore item fails.
- Restore the source server's original running-container state on normal exit, errors, and signals.
- Keep containers that were already stopped in their original stopped state.
- Remove invalid top-level `local` declarations from generated scripts.

### Restore fidelity

- Add `RESTORE_EXISTING=replace|skip|fail`; the default `replace` performs a complete configuration restore.
- Preserve custom network driver, IPAM, subnet, gateway, IPv6, options, labels, static IPs, and aliases.
- Merge all Compose `-f` files into a canonical restore configuration.
- Preserve relative and absolute `env_file` inputs as a fallback.
- Restore fractional CPU limits, health-check forms, and container namespace references.

### Compatibility

- Add `--backup` and `--restore=URL` non-interactive modes.
- Add fallbacks for systems without GNU `flock`, `timeout`, `sed -i`, or `grep -P`.
- Keep Bash 4.0 as the minimum supported version.

### Low-friction security

- Use owner-only permissions for generated artifacts.
- Generate and verify a SHA-256 manifest automatically.
- Validate archive paths before extraction.
- Preserve random URL paths in Python and BusyBox HTTP modes.
- Add no-store, attachment, and nosniff HTTP response headers.

### Testing

- Add unit tests for failure propagation, generated scripts, checksums, archives, and Compose parsing.
- Add Docker integration coverage for networks, static IPs, health checks, fractional CPU limits, Compose, and existing-container policies.
- Add GitHub Actions jobs for syntax, ShellCheck, shfmt, unit tests, and Docker integration.
