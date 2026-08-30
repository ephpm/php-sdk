# php-sdk

Pre-built PHP embed SAPI static libraries (`libphp.a` / `php8embed.lib`) plus headers, for the OS/arch/PHP-version combinations [ePHPm](https://github.com/ephpm/ephpm) supports.

Built with [static-php-cli](https://github.com/crazywhalecc/static-php-cli) — specifically the [`luthermonson/static-php-cli`](https://github.com/luthermonson/static-php-cli) fork, pinned by `SPC_VERSION` in `.github/workflows/build.yml`. Every SDK is a `spc build --build-embed` output: a static `libphp.a`, never a shared `libphp.so`.

## What this builds

| Platform | Tarball suffix | Output |
|----------|----------------|--------|
| Linux x86_64 (glibc, floor 2.28) | `-linux-x86_64-gnu` | `lib/libphp.a` + headers, ZTS |
| Linux aarch64 (glibc, floor 2.28) | `-linux-aarch64-gnu` | `lib/libphp.a` + headers, ZTS |
| Linux x86_64 (musl, fully static) | `-linux-x86_64` | `lib/libphp.a` + headers, ZTS |
| Linux aarch64 (musl, fully static) | `-linux-aarch64` | `lib/libphp.a` + headers, ZTS |
| macOS aarch64 | `-macos-aarch64` | `lib/libphp.a` + headers, ZTS |
| Windows x86_64 | `-windows-x86_64` | `lib/php8embed.lib` + dep `.lib`s + headers, ZTS |
| Linux x86_64 (glibc, **NTS**) | `-linux-x86_64-gnu-nts` | `lib/libphp.a` + headers, non-thread-safe |
| Linux aarch64 (glibc, **NTS**) | `-linux-aarch64-gnu-nts` | `lib/libphp.a` + headers, non-thread-safe |
| Windows x86_64 (**experimental**, clang-cl + TAILCALL VM) | `-windows-x86_64-clang` | `lib/php8embed.lib` + dep `.lib`s + headers, ZTS |

The glibc floor is 2.28 (built on AlmaLinux 8 with `gcc-toolset-13`), so a consumer binary linked against these runs on RHEL/Alma 8, Ubuntu 20.04+, Debian 10+, Amazon Linux 2023 and Fedora 40+.

### ZTS and NTS

**ZTS is the default and is unsuffixed.** ePHPm is a threaded server and links the ZTS SDK; renaming those assets breaks it. The `-gnu-nts` variants exist for consumers that cannot use a thread-safe build.

Detect which one you have from `include/php/main/php_config.h`: thread-safe builds define `ZTS 1`, non-thread-safe builds do not define `ZTS` at all.

NTS tarballs:

- are Linux-glibc only (x86_64 and aarch64),
- are **not** part of a `platform=all` build and do not gate release completeness — a failed NTS build never blocks a release,
- carry `ffi` in addition to the shared extension set (see below),
- are kept current only for the minors listed under `minors_nts` in `versions.json`.

### Experimental: Windows clang-cl / TAILCALL VM lane

`-windows-x86_64-clang` is an additive, explicitly-dispatched lane
(`platform=windows-x86_64-clang`) that builds PHP itself with clang-cl and
hand-defines `HAVE_PRESERVE_NONE`, so PHP 8.5+ selects the
`ZEND_VM_KIND_TAILCALL` interpreter instead of the slow `ZEND_VM_KIND_CALL`
every MSVC build gets. Dependencies stay MSVC-built; clang-cl is
MSVC-ABI-compatible and the resulting `php8embed.lib` links into MSVC-target
consumers unchanged. The build hard-fails unless the compiled VM kind is
verifiably TAILCALL.

**Status: experimental, but a measured performance win with the pinned
toolchain.** On PHP 8.5.7 CLI (Ryzen 9 5950X, 2026-08, best-of-5 hrtime
loops), LLVM **22.1.8** clang-cl + TAILCALL runs the dispatch-bound int loop
**1.7x faster** than the MSVC lane's CALL VM (8.4 ms vs 14.2 ms) and wins on
string-append and function-call loops too; the mixed reference loop drops
from 4.4 ms to 2.7 ms — Windows lands within ~12% of the same loop on Linux
(HYBRID VM). Two sharp edges, which is why this stays experimental:

- **The toolchain must be the pinned LLVM release.** The VS-bundled
  clang-cl 19.1.5 generates Zend-engine code ~45–90% *slower* than MSVC —
  enough to swamp the VM-kind win and end up slower than the stock lane.
  The workflow pins `LLVM_VERSION` and hard-fails on mismatch.
- **The build hard-fails unless the compiled VM kind is verifiably
  TAILCALL** (disassembled out of `php8embed.lib`), so it can never silently
  regress to the CALL VM.

It is never part of `platform=all`, never gates a release, and must not be
moved into `platforms_required` until it has soaked as an opt-in lane.

### macOS Zend VM kind

macOS SDKs do **not** ship the HYBRID VM. The macOS build uses clang (Homebrew
LLVM), and clang defines `__GNUC__` but fails PHP's `HAVE_GCC_GLOBAL_REGS`
configure check, so the fast `ZEND_VM_KIND_HYBRID` interpreter is never
selected. The result depends on the PHP minor:

| macOS PHP | Zend VM kind | Notes |
|-----------|--------------|-------|
| 8.5+ | `TAILCALL` (5) | clang ≥ 19 `musttail` + `preserve_none`; ~HYBRID speed |
| 8.4 | `CALL` (1) | slowest VM — no TAILCALL path before 8.5 |
| 8.3 | `CALL` (1) | slowest VM — no TAILCALL path before 8.5 |

HYBRID would require building PHP **and** its ~20 dependency libraries with real
GCC on `aarch64-apple-darwin`. That is not a supported static-php-cli
configuration: `config/env.ini`'s `[macos]` section hardcodes `CC=clang`, and
the toolchain classes only set the `SPC_LINUX_DEFAULT_*` vars the macOS section
never reads — so `SPC_TOOLCHAIN=GccNativeToolchain` does not switch the macOS
compiler. Wiring that up (plus getting Homebrew GCC to pass
`HAVE_GCC_GLOBAL_REGS` for the aarch64 global registers and produce a working
JIT, which the build already had to abandon *Apple* clang for) is a large spc
change PHP upstream does not test on macOS. Until then: **use macOS PHP 8.5 for
CPU-bound workloads.** The build logs the selected VM kind (macOS "Record Zend
VM kind" step) and warns when a pre-8.5 macOS SDK lands on CALL.

## Tarball layout

```
lib/                       libphp.a (or php8embed.lib) + every static dep archive
include/php/
  main/                    includes php_config.h (ZTS marker) and php_version.h
  Zend/
  TSRM/
  ext/
  sapi/embed/php_embed.h
bin/php-config             Linux and macOS only
THIRD-PARTY-NOTICES.txt
```

Assets are named:

```
php-sdk-{php_version}-{os}-{arch}[-gnu][-nts].tar.gz
```

### `bin/php-config`

A relocatable POSIX-sh shim, generated by `tools/mk-sdk-metadata.sh` at package time. It resolves its own prefix at run time, so the tarball can be extracted anywhere. It exists because build scripts that expect a system PHP (`php-config --includes`) run it unconditionally.

Supported: `--prefix`, `--includes`, `--include-dir`, `--ldflags`, `--libs`, `--extension-dir`, `--version`, `--vernum`, `--php-sapis`, `--help`.

Deliberately refused, with a message and a non-zero exit, rather than answered with a plausible lie:

- `--php-binary` — this SDK ships no PHP executable.
- `--configure-options` — static-php-cli strips the configure line from the build.

`--libs` enumerates the static archives in `lib/`. It is a starting point, not a verified link line: whole-archive and symbol-ordering decisions belong to the consumer. See [ePHPm's `crates/ephpm/build.rs`](https://github.com/ephpm/ephpm/blob/main/crates/ephpm/build.rs) for a working static link against these tarballs, including the `-Wl,--export-dynamic` that lets `extension=`-loaded `.so` files resolve `zend_*` symbols against the host binary.

No `php-config` is generated on Windows — it is a shell script and nothing in the MSVC toolchain consumes one.

## Extensions

Compiled into `libphp.a` on Linux and macOS:

```
bcmath, bz2, calendar, ctype, curl, dom, exif, fileinfo, filter, ftp, gd,
gettext, gmp, hash, iconv, intl, mbregex, mbstring, mysqli, mysqlnd, opcache,
openssl, pcntl, pcre, pdo, pdo_mysql, pdo_pgsql, pdo_sqlite, pgsql, phar,
posix, session, shmop, simplexml, soap, sockets, sodium, sqlite3, sysvmsg,
sysvsem, sysvshm, tokenizer, xml, xmlreader, xmlwriter, xsl, zip, zlib
```

The NTS variants additionally include `ffi`.

Windows drops the Unix-only entries (`pcntl`, `posix`, `sysv*`), plus `gmp`, `pgsql` and `pdo_pgsql`, which static-php-cli cannot build statically on Windows today. It also does not yet carry `shmop` or `sockets` — PHP supports both there, but neither has been validated through spc's Windows toolchain from this repo.

`ffi` is not in the shared extension set on purpose. static-php-cli's `ext-ffi` passes `--enable-zend-signals`, and extension arguments land after the target arguments on the configure line, so it would override the `--disable-zend-signals` that spc emits for ZTS builds — silently changing signal behavior in the SDK ePHPm links. NTS builds emit no `--disable-zend-signals`, so `ffi` rides along there.

Loadable **shared** ZTS extensions (`igbinary`, `msgpack`, `apcu`, `redis`, `mongodb`) are a separate artifact built by `.github/workflows/extensions.yml` and published under `ext-<version>` tags. That catalog is ZTS-only by design: Debian and Sury publish no ZTS builds, which is the gap it fills. There is no NTS catalog.

## Building

```bash
# full release
gh workflow run build.yml -f php_version=8.5.2

# one platform (uploads to the existing release, leaves other assets alone)
gh workflow run build.yml -f php_version=8.5.2 -f platform=linux-aarch64-gnu

# non-thread-safe variant
gh workflow run build.yml -f php_version=8.4.23 -f platform=linux-x86_64-gnu-nts
```

### Pre-release (beta/RC) builds

static-php-cli resolves `php-src` from php.net's **GA-only** release feed, and
its `--with-php` accepts only numeric `x.y`/`x.y.z`. So a beta/RC cannot go
through the normal path. Set `php_src_url` to the upstream pre-release tarball
(the release manager's QA dir, `downloads.php.net/~<RM>/`); every OS leg then
fetches `php-src` from that URL and hands it to spc via `--custom-url`/
`--custom-local`, while `--with-php` gets the numeric `major.minor`. The
resulting release tag (`v<php_version>`) is marked **prerelease**.

```bash
gh workflow run build.yml \
  -f php_version=8.6.0beta1 -f platform=all \
  -f php_src_url=https://downloads.php.net/~svpernova09/php-8.6.0beta1.tar.gz
```

Betas are **not** added to `versions.json` `minors` (watch-php.yml polls the GA
feed and would error on a non-GA minor) and never gate a stable release. This
lane is experimental: no spc release has explicit 8.6 support — it builds
because spc has no upper-version cap and reads the real `PHP_VERSION_ID` from
the supplied source. The Windows embed leg for a brand-new beta is unproven.

**Any dispatch from a branch other than `main` MUST set `release_tag_suffix`.** On 2026-07-13 a validation build from a side branch uploaded to the plain `v8.5.7` tag and overwrote four production assets. The input exists to make that impossible:

```bash
gh workflow run build.yml --ref my-branch \
  -f php_version=8.5.7 -f platform=linux-x86_64-gnu -f release_tag_suffix=-mytest
```

`watch-php.yml` polls php.net every 6 hours, mirrors new php-src tarballs to the `php-sources` release tag, and dispatches builds for anything missing.

## Dependency mirror

Builds do not fetch PHP or its GNU dependencies from upstream. Both come from this repo's own `php-sources` release tag, fetched with plain `curl` and handed to static-php-cli as `file://` custom URLs.

| Asset on `php-sources` | Populated by | Consumed by |
|---|---|---|
| `php-X.Y.Z.tar.gz` | `watch-php.yml` | `build.yml`, `extensions.yml` |
| `libiconv-*`, `gettext-*`, `ncurses-*`, `libunistring-*`, `libidn2-*` | `mirror-deps.yml` | `build.yml`, `extensions.yml` |
| `gnu-deps-manifest.txt`, `SHA256SUMS` | `mirror-deps.yml` | `build.yml`, `extensions.yml` |

Those libraries resolve through static-php-cli `type: filelist` sources pointed at `https://ftpmirror.gnu.org/gnu/<pkg>/`. That host is a redirector to volunteer backend mirrors and returns HTTP errors when it picks a bad one. None of the five has a `source-mirror` fallback in spc, so a single bad backend fails the whole `spc download` and therefore the build. That took every scheduled build in this repo down from 2026-08-06 onward.

`gmp` is also GNU-hosted but is **not** in the mirror: it is the one GNU dependency with its own `source-mirror` fallback in spc, so `mirror-deps.yml` resolved it from there and correctly did not select it. The mirrored set is whatever spc actually resolved from `ftpmirror.gnu.org`, not a fixed list.

Refresh the mirror when you want newer dependency versions:

```bash
gh workflow run mirror-deps.yml                      # resolve + upload
gh workflow run mirror-deps.yml -f dry_run=true      # resolve + print only
```

`mirror-deps.yml` runs on a GitHub-hosted runner (different egress from the self-hosted fleet) but resolves inside the same `almalinux:8` container with the same `SPC_TARGET`, so it picks exactly the artifacts the fleet would have. The set is derived from spc's own `downloads/.cache.json` — every artifact whose source URL is on `ftpmirror.gnu.org`.

Note the tradeoff: `filelist` sources normally track the newest tarball in the directory index on every build. Once mirrored, builds pin to whatever was current when `mirror-deps.yml` last ran. That is the same tradeoff `php-src` already makes, and it stops builds drifting underneath us.

If the manifest is missing from the release tag, builds log a warning and fall back to fetching from upstream GNU mirrors — the pre-mirror behaviour, and the known failure mode.

## Consuming

ePHPm's release workflow:

```yaml
- name: Download PHP SDK
  run: |
    gh release download v${{ matrix.php }} \
      --repo ephpm/php-sdk \
      --pattern "php-sdk-*-${{ matrix.os }}-${{ matrix.arch }}.tar.gz" \
      --output php-sdk.tar.gz
    mkdir -p php-sdk && tar xzf php-sdk.tar.gz -C php-sdk
```

then builds with `PHP_SDK_PATH=php-sdk cargo build --release`.

## Licensing

The MIT license in this repository covers the workflows and scripts here. It does **not** cover the contents of the published tarballs: those are an aggregate of PHP (PHP License 3.01 / Zend Engine License 2.00) and roughly twenty upstream libraries, each under its own terms — including a bundled `libstdc++.a` carrying the GCC Runtime Library Exception.

Every tarball ships a `THIRD-PARTY-NOTICES.txt` listing the components, their SPDX identifiers, and where to get the full license texts. Read it before redistributing anything built from this SDK.
