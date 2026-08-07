# php-sdk

Pre-built PHP embed SAPI static libraries (`libphp.a` / `php8embed.lib`) for every OS, architecture, and PHP version that [ePHPm](https://github.com/ephpm/ephpm) supports.

## What this builds

| OS | Arch | Output |
|----|------|--------|
| Linux | x86_64 | `libphp.a` + headers (musl, static) |
| Linux | aarch64 | `libphp.a` + headers (musl, static) |
| Linux | x86_64 | `libphp.a` + headers (glibc, `-gnu` tarball suffix) |
| Linux | aarch64 | `libphp.a` + headers (glibc, `-gnu` tarball suffix) |
| macOS | x86_64 | `libphp.a` + headers |
| macOS | aarch64 | `libphp.a` + headers |
| Windows | x86_64 | `php8embed.lib` + `php8embed.dll` + headers (from windows.php.net) |

## PHP versions

Each release tag corresponds to a PHP version (e.g. `v8.5.2`). Assets are tarballs named:

```
php-sdk-{php_version}-{os}-{arch}.tar.gz
```

Inside each tarball:
```
lib/libphp.a          # (or lib/php8embed.lib + lib/php8embed.dll on Windows)
include/php/
  main/
  Zend/
  TSRM/
  sapi/
```

## Usage in ephpm

ephpm's release workflow downloads the appropriate SDK:

```yaml
- name: Download PHP SDK
  run: |
    gh release download v${{ matrix.php }} \
      --repo ephpm/php-sdk \
      --pattern "php-sdk-*-${{ matrix.os }}-${{ matrix.arch }}.tar.gz" \
      --output php-sdk.tar.gz
    mkdir -p php-sdk && tar xzf php-sdk.tar.gz -C php-sdk
```

Then builds with `PHP_SDK_PATH=php-sdk cargo build --release`.

## Building

Triggered manually or when a new PHP version tag is pushed:

```bash
gh workflow run build.yml -f php_version=8.5.2
```

## Dependency mirror

Builds do not fetch PHP or its GNU dependencies from upstream. Both come from this repo's own `php-sources` release tag, fetched with plain `curl` and handed to static-php-cli as `file://` custom URLs.

| Asset on `php-sources` | Populated by | Consumed by |
|---|---|---|
| `php-X.Y.Z.tar.gz` | `watch-php.yml` | `build.yml`, `extensions.yml` |
| `libiconv-*`, `gettext-*`, `ncurses-*`, `libunistring-*`, `libidn2-*`, `gmp-*` | `mirror-deps.yml` | `build.yml`, `extensions.yml` |
| `gnu-deps-manifest.txt`, `SHA256SUMS` | `mirror-deps.yml` | `build.yml`, `extensions.yml` |

Those six libraries resolve through static-php-cli `type: filelist` sources pointed at `https://ftpmirror.gnu.org/gnu/<pkg>/`. That host is a redirector to volunteer backend mirrors and returns HTTP errors when it picks a bad one. Five of the six — everything except `gmp` — have **no** `source-mirror` fallback in spc, so a single bad backend fails the whole `spc download` and therefore the build. That took every scheduled build in this repo down from 2026-08-06 onward.

Refresh the mirror when you want newer dependency versions:

```bash
gh workflow run mirror-deps.yml                      # resolve + upload
gh workflow run mirror-deps.yml -f dry_run=true      # resolve + print only
```

`mirror-deps.yml` runs on a GitHub-hosted runner (different egress from the self-hosted fleet) but resolves inside the same `almalinux:8` container with the same `SPC_TARGET`, so it picks exactly the artifacts the fleet would have. The set is derived from spc's own `downloads/.cache.json` — every artifact whose source URL is on `ftpmirror.gnu.org` — not from a hardcoded list.

Note the tradeoff: `filelist` sources normally track the newest tarball in the directory index on every build. Once mirrored, builds pin to whatever was current when `mirror-deps.yml` last ran. That is the same tradeoff `php-src` already makes, and it stops builds drifting underneath us.

If the manifest is missing from the release tag, builds log a warning and fall back to fetching from upstream GNU mirrors — the pre-mirror behaviour, and the known failure mode.

## Extensions included

bcmath, calendar, ctype, curl, dom, exif, fileinfo, filter, gd, hash, iconv, mbstring, mysqli, mysqlnd, openssl, pcntl, pcre, pdo, pdo_mysql, phar, posix, session, simplexml, sodium, tokenizer, xml, xmlreader, xmlwriter, zip, zlib
