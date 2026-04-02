# php-sdk

Pre-built PHP embed SAPI static libraries (`libphp.a` / `php8embed.lib`) for every OS, architecture, and PHP version that [ePHPm](https://github.com/ephpm/ephpm) supports.

## What this builds

| OS | Arch | Output |
|----|------|--------|
| Linux | x86_64 | `libphp.a` + headers (musl, static) |
| Linux | aarch64 | `libphp.a` + headers (musl, static) |
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

## Extensions included

bcmath, calendar, ctype, curl, dom, exif, fileinfo, filter, gd, hash, iconv, mbstring, mysqli, mysqlnd, openssl, pcntl, pcre, pdo, pdo_mysql, phar, posix, session, simplexml, sodium, tokenizer, xml, xmlreader, xmlwriter, zip, zlib
