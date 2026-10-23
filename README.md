# el8-php73-security

Patched PHP 7.3 RPMs for **EL8** (Rocky Linux, AlmaLinux, RHEL 8), for Remi's SCL packages
`php73-php-*`, fixing **CVE-2026-109618** and **CVE-2026-109619** (GHSA-w8hw-w9fx-j79w,
GHSA-6wmf-4rv5-p3rp). The repo also includes an installer that finds the PHP installs on a
server, upgrades them and can roll the upgrade back.

There is no official fix for PHP 7.3: upstream published fixes for 8.2–8.5 and backport
branches for 7.4, 8.0 and 8.1, and Remi's latest 7.3 package (`7.3.33-22`, August 2026)
predates the CVEs. These packages are **Remi's `php73-php-7.3.33-22` source package plus
our port of the upstream 7.4 fix** (`php-7.3-cve-2026-109618.patch`).

> ⚠️ PHP 7.3 has been end-of-life since December 2021. This is a stop-gap. The real fix is
> to move to a supported PHP version. Test on a non-production server first.

## Quick start

```bash
curl -fLO https://raw.githubusercontent.com/bagsiz/el8-php73-security/main/php73-cve.sh
chmod +x php73-cve.sh

./php73-cve.sh status      # list every PHP on the server and its patch status
./php73-cve.sh install     # upgrade the installed php73-php-* packages (asks for confirmation; -y to skip)
./php73-cve.sh uninstall   # roll back to the previous versions
```

The RPMs are published as [release assets](https://github.com/bagsiz/el8-php73-security/releases/tag/v7.3.33-22.1).
`install` downloads the archive it needs and checks it against a SHA256 that is hardcoded
in the script. If the server has no internet access, download `php73-rpms-scl.tar.gz` (and
`el8-rpmrebuild-tools.tar.gz`) by hand and put them next to the script.

`install` uses `dnf`, so dependencies that are not yet installed (for example a newer
`libicu69`, `gd3php` or `oniguruma5php` from Remi's repository) are pulled from the
server's enabled repositories.

### Network timeouts

Network waits are capped at **10 seconds** so the script does not hang on unreachable
hosts.

| Step | Behaviour |
|---|---|
| Release download (`curl`) | Gives up if no connection is made within 10s, or if the download stalls (below 1 KB/s) for 10s. No retry. A slow download that is still moving is not cut off |
| `dnf` (backup, `rpmrebuild` install, install, rollback) | 10s per request, one retry, and unreachable repositories are skipped (`skip_if_unavailable`) |

Environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `PHP73CVE_NET_TIMEOUT` | `10` | Network timeout in seconds, e.g. `PHP73CVE_NET_TIMEOUT=30 ./php73-cve.sh install` on a slow link |
| `PHP73CVE_RELEASE_URL` | this repo's `v7.3.33-22.1` release | Download the archives from a mirror or an internal server instead |

## What it detects

`status` and `install` start by listing every PHP they can find on the server:

- the `php`, `php73`, `php7.3`, `php-fpm` and `php-cgi` commands (symlinks are resolved)
- copies under `/usr/local` and `/opt`, and under `/opt/remi/php*`
- running `php-fpm` master processes
- PHP modules loaded by Apache (mod_php)

For each binary it looks up the RPM that owns it:

| Found | Action |
|---|---|
| `php73-php-*` from Remi SCL (`/opt/remi/php73`, `php73-php-fpm` service) | upgraded |
| AppStream `php` (7.2, 7.4, …), Remi module `php:remi-7.3`, other Remi SCLs, source builds | reported only, not changed |

Example `status` output from the test server (set up like the Magento server: Remi `php73`
behind php-fpm, AppStream php 7.2 installed next to it):

```
==> PHP on this server
  [left as is] /usr/bin/php  [PHP 7.2.24]  (command 'php') : PHP 7.2.24 (not 7.3)
  [patchable ] /opt/remi/php73/root/usr/bin/php  [PHP 7.3.33]  (command 'php73'; link: /usr/bin/php73)
  [left as is] /usr/sbin/php-fpm  [PHP 7.2.24]  (command 'php-fpm') : PHP 7.2.24 (not 7.3)
  [left as is] /usr/bin/php-cgi  [PHP 7.2.24]  (command 'php-cgi') : PHP 7.2.24 (not 7.3)
  [patchable ] /opt/remi/php73/root/usr/bin/php-cgi  [PHP 7.3.33]  (link: /usr/bin/php73-cgi)
  [patchable ] /opt/remi/php73/root/usr/sbin/php-fpm  [PHP 7.3.33]  (RUNNING: php-fpm master pid 233 (/etc/opt/remi/php73/php-fpm.conf))
==> Installed packages: php73 (Remi SCL)
  php73-php-bcmath                 7.3.33-21.el8.remi       UNPATCHED (patched build available)
  php73-php-cli                    7.3.33-21.el8.remi       UNPATCHED (patched build available)
  php73-php-common                 7.3.33-21.el8.remi       UNPATCHED (patched build available)
  ...
  php73-php-pear                   1.10.18-4.el8.remi       left as is (not shipped here)
  php73-php-pecl-apcu              5.1.28-1.el8.remi        left as is (not shipped here)
  php73-php-pecl-imagick           3.8.1-4.el8.remi         left as is (not shipped here)
  ...
==> Services
  php73-php-fpm    active
```

The script only replaces PHP packages that are already installed. It does not touch
packages that are not in the release: PECL extensions (`php73-php-pecl-*`), `php73-php-pear`,
`php73-runtime`, or loaders such as ionCube. They keep working because the PHP API/ABI is
unchanged (tested with apcu, imagick, mcrypt, zip and the ionCube Loader).

## What `install` does

1. Runs pre-flight checks: root, EL8, x86_64, and `php-fpm -t` must already pass.
2. Downloads the RPM archive and verifies it against the pinned SHA256, then verifies
   each RPM against `SHA256SUMS`.
3. Saves a backup under `/var/lib/php73-cve-2026/scl/backup-<timestamp>/`:
   - the RPMs of the currently installed versions (see [Rollback backups](#rollback-backups))
   - the PHP configuration (`/etc/opt/remi/php73`)
   - the list of services that were running
4. Upgrades the packages with `dnf install`.
5. Checks the result:
   - `php -v`
   - `php -m` must load without warnings
   - the changelog must contain the CVE
   - `php-fpm -t` (and `apachectl -t` if httpd runs) must pass
6. Restarts the services that were running (`php73-php-fpm`, `httpd`).
7. **Rolls back automatically** if any of these steps fails.

`uninstall` puts the backed-up RPMs back with `rpm -Uvh --oldpackage`, so the server
returns to exactly the versions it had. Configuration files are not restored
automatically; the backup path is printed.

### Rollback backups

dnf does not keep the `.rpm` files of installed packages by default (`keepcache=0`), and
Remi's repository only carries the newest builds (`7.3.33-21` and `-22`). A server running
an older build, such as `7.3.30-1`, usually has that RPM nowhere. Before upgrading, the
script therefore looks for the RPM of each installed version in this order:

| # | Source | Notes |
|---|---|---|
| 1 | **dnf cache** (`/var/cache/dnf`) | Present when `keepcache=1` or the package was downloaded earlier. The file must match the exact name-version-release and pass `rpm -K` |
| 2 | **repositories** (`dnf download`) | The exact version, if the repository still has it |
| 3 | **`rpmrebuild`** | Rebuilds the RPM from the RPM database and the installed files. The result is **unsigned** and not byte-identical to the original, and config files go in as they are on disk now. Files missing on disk are left out |
| – | none of the above | The script warns and asks before continuing. `uninstall` then moves those packages to the newest version left in the repositories (Remi `7.3.33-22`, unpatched) |

#### rpmrebuild on servers without matching repositories

`rpm-build` only installs on the exact `rpm` version it was built for, and a server on an
older minor release (8.4, 8.6, …) gets the 8.10 version from current mirrors. The release
therefore also ships `el8-rpmrebuild-tools.tar.gz`:

- `rpmrebuild-2.16-3.el8` from EPEL 8
- `rpm-build` for every `rpm` version Rocky Linux 8 shipped, 12 in all from 8.3 to 8.10
  (`4.14.3-4.el8` … `4.14.3-32.el8_10`). AlmaLinux and RHEL use the same versions
- all packages are signed by Rocky Linux or EPEL 8 (`rpm -K` checked); the archive's SHA256
  is pinned in the script

When `rpmrebuild` is needed and not installed, the script installs the matching
`rpm-build` and `rpmrebuild` with `rpm -i --nodeps`, and removes them again once the
backup is done. Only if that fails does it try `dnf install rpmrebuild`.

The source used for each package is printed during `install` and `uninstall`, and is
recorded in `sources.txt` inside the backup directory.

## Package contents (`7.3.33-22.1.el8`)

- Remi Collet's `php73-php-7.3.33-22` SRPM (2026-08-07), checked against Remi's 2026 key
  (`Header V4 EdDSA/SHA512 Signature, key ID befa00e2: OK`). It contains every security fix
  Remi backported to 7.3, more than 25 since `7.3.30` (2021).
- Plus `php-7.3-cve-2026-109618.patch`, our port of the upstream 7.4 fix (branch
  `PHP-7.4-CVE-2026-109618-109619`).
- Built on **Rocky Linux 8.4** (glibc `2.28-151`), so the packages run on 8.4 and every later
  EL8 release.

### About the 7.3 patch

15 of the 17 files of the upstream 7.4 patch applied unchanged. The rest was ported by hand:

- `Zend/zend_execute_API.c`: 7.3's `shutdown_executor` is laid out differently. The same
  state is reset (error/exception handlers and their stacks, `EG(exception)`,
  `EG(error_handling)`, the objects store) on the fast and the full shutdown path.
- `main/rfc1867.c`: only `Content-Disposition` and `Content-Type` part headers are kept,
  duplicates are ignored; `substring_conf` uses `size_t`.
- `Zend/zend_vm_def.h`: 7.3 had no overflow check on the in-place `CONCAT` path; it is added,
  and `zend_vm_execute.h` was regenerated with PHP's own `zend_vm_gen.php` (which reproduces
  the shipped file byte for byte from the unpatched source).
- Everything else as upstream: out-of-memory and overflow errors end the worker with
  `_exit(1)` (`zend_mm_safe_error_ex`), `array_init_singleton` for request variables,
  `zend_llist_destroy`, SAPI and request shutdown pointer resets, and
  `session.upload_progress` disabled.

## Behaviour changes

These come from the upstream fix:

- A request that exceeds `memory_limit` (or hits another out-of-memory condition)
  terminates the worker process with `exit(1)` instead of unwinding. PHP-FPM starts a new
  worker. Shutdown functions and destructors do not run for that request.
- The out-of-memory fatal error goes to stderr, not to `error_log`. To see it in the
  PHP-FPM log, set `catch_workers_output = yes` in the pool configuration.
- `session.upload_progress` is disabled.

## FAQ

**Packages marked "left as is" (`php73-php-pecl-*`, …): are they vulnerable, do they need updating?**
Not for these CVEs. CVE-2026-109618/109619 are in the PHP core: the Zend engine, request
startup and shutdown, multipart parsing and the session extension. Those are fixed by
upgrading the `php73-php-*` core packages. PECL extensions are separate code that runs
inside the patched core.

**`install` fails with "file /etc/opt/remi/php73/php-fpm.d/www.conf ... conflicts with file from package php-fpm-7.2.24".**
php73's pool directory was linked to the OS php-fpm's (`/etc/opt/remi/php73/php-fpm.d ->
/etc/php-fpm.d`), usually so that VestaCP manages php73's pools. rpm then sees one file as
owned by two packages and refuses the upgrade; nothing is changed. Fix the layout with
[vesta-remi-php-fpm](https://github.com/bagsiz/vesta-remi-php-fpm) (`status`, `apply`;
Vesta keeps working), then run `install` again.

**The server also has AppStream `php` 7.2 (`/usr/bin/php`). What about it?**
It is reported but not changed. If nothing uses it (no `php-fpm` service, no cron jobs
calling `/usr/bin/php`), remove it; otherwise it has to be patched or upgraded separately.

## Testing

- **php-src test suite** (run by the spec during the build, 10,370 tests): 9,523 passed.
  Of the 25 failures, 16 are `ext/openssl` tests whose test certificates have expired; the
  same 16 fail with Remi's unpatched `7.3.33-22`. The other 9 are the expected ones, the
  same as for the official 7.4 fix: the 8 `session.upload_progress` (`rfc1867*`) tests, and
  a cosmetic difference in one out-of-memory message (`bug45392`).
- **Installer**, in a clean Rocky Linux 8.4 container set up like the production server
  (Remi `php73-php-*` with the same package set, PECL apcu/imagick/mcrypt/zip, ionCube
  Loader for 7.3, AppStream php 7.2 next to it), starting from Remi's `7.3.33-21`:
  **49 of 49 checks passed**.
  - `install`: every core package moves to `7.3.33-22.1.el8`; PECL packages and
    `php73-php-pear` are untouched; php-fpm serves requests; apcu, imagick, mcrypt, zip,
    intl, gd, mbstring, pdo_mysql, soap, OPcache and **ionCube Loader** still load; `php -m`
    shows no warnings; multipart file upload works; after a request that exceeds
    `memory_limit` the next request is served; the changelog contains the CVE
  - re-running `install` is a no-op; `uninstall` returns to `7.3.33-21` and php-fpm serves
    again; a second `uninstall` refuses
  - rollback backups from each source on its own: dnf cache, `dnf download`, and
    `rpmrebuild` with the bundled `rpm-build` (removed again afterwards). Each gives a
    working `uninstall`
  - without any backup, `uninstall` falls back to the newest repository version (`-22`)
  - automatic rollback when verification fails, a tampered RPM being refused, and no php73
    on the host
- **Not covered:** real systemd, nginx and the Magento application itself. The container
  used a stub `systemctl` and talked to php-fpm over FastCGI directly. Run `status` and
  `install` on one server and check the site before rolling out further.

## Disclaimer

**USE AT YOUR OWN RISK.** This project, including the installer script, the patches and
the RPM packages, is provided **"AS IS", WITHOUT WARRANTY OF ANY KIND**, express or implied.
This includes, without limitation, warranties of merchantability, fitness for a particular
purpose, security and non-infringement.

- **Not official.** The packages are unofficial rebuilds of Remi Collet's source packages
  with an unofficial patch. They are not built, reviewed or supported by Remi Collet, Red
  Hat, the Rocky Enterprise Software Foundation or the PHP project, and may contain build
  or packaging problems.
- **Your responsibility.** You decide whether to use this software, and you are
  responsible for testing it, for backing up your systems and data, and for any change you
  make to your servers. Running unsupported software (PHP 7.3) carries risk that no patch
  removes. The recommended long-term fix is to move to a supported PHP version.
- **No liability.** In no event shall the authors or contributors be liable for any claim,
  damages or other liability arising from, out of, or in connection with this software or
  its use. This covers direct, indirect, incidental, special, consequential or punitive
  damages, data loss, downtime and security incidents, whether in contract, tort or
  otherwise, even if advised of the possibility of such damage.
- **No support obligation.** There is no commitment to support, maintenance, updates or
  security fixes.
- **Not security advice.** Nothing in this repository is professional, security or legal
  advice.
- **No affiliation.** This project is not affiliated with, endorsed by or sponsored by:
  - The PHP Group or the PHP project
  - Remi Collet / remirepo
  - Red Hat, Inc., the Rocky Enterprise Software Foundation or AlmaLinux OS Foundation
  - ionCube Ltd.
  - GitHub, Inc.

  "PHP", "Rocky Linux", "AlmaLinux", "Red Hat", "ionCube" and other names are trademarks of
  their respective owners and are used here only to describe compatibility.

## License

- **Installer script and documentation** (`php73-cve.sh`, `README.md`): MIT License, see
  [`LICENSE`](LICENSE).
- **RPM packages (release assets):** these contain third-party software that stays under
  its original license:
  - PHP is under the [PHP License v3.01](https://www.php.net/license/3_01.txt). The PHP
    patches in the source packages, including `php-7.3-cve-2026-109618.patch`, are derived
    from php-src and fall under the same license.
  - Zend Engine is under the Zend Engine License v2.00.
  - Bundled libraries and extensions are under their own licenses.
  - The RPM spec files and packaging come from Remi's repository under the MIT License.

  License texts are included in the packages:
  `/opt/remi/php73/root/usr/share/licenses/php73-php-common-7.3.33/`.

This product includes PHP software, freely available from <http://www.php.net/software/>.
