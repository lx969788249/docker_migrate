# Changelog

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
