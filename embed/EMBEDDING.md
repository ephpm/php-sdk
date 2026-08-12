# Embedding this SDK

This file ships in the `-gnu-nts` (static, `lib/libphp.a`) and
`-gnu-nts-shared` (shared, `lib/libphp.so`) Linux tarballs.

## Static (`-gnu-nts`): linking libphp.a

`bin/php-config` is relocatable (`--includes` for the `-I` set, `--libs`
for the archive group plus `-lm -ldl -lpthread`). Minimal embed build:

```sh
cc $(bin/php-config --includes) \
   your_embed.c embed/resolver_shim.c \
   -L lib $(bin/php-config --libs)
```

### resolver_shim.c — required on glibc >= 2.34

`libphp.a` is compiled against glibc 2.28 and references the underscored
resolver names (`__dn_expand`, `__res_nsearch`, `__dn_skipname`). glibc
2.34 moved libresolv into libc and stripped the unversioned compatibility
aliases, so linking on Ubuntu 22.04+ / Debian 12+ / RHEL 9+ fails with
undefined references to those symbols. Compile `embed/resolver_shim.c`
(MIT, from the ephpm project) into your build as shown above; it maps the
underscored names to the public `dn_expand`/`res_nsearch`/`dn_skipname`.
On glibc < 2.34 it is harmless.

### C++ runtime

`lib/libstdc++.a` is the archive the SDK's own C++ dependencies (ICU for
intl, etc.) were compiled against. `php-config --libs` includes it via the
group; do not substitute the host's copy across a libc flavor boundary.

## Shared (`-gnu-nts-shared`): linking or dlopening libphp.so

`lib/libphp.so` has the SDK's dependencies statically linked in and
exports the embed API (`php_embed_init` / `php_embed_shutdown`).

```sh
cc $(bin/php-config --includes) \
   your_embed.c -L lib -lphp -Wl,-rpath,'$ORIGIN/../lib'
```

The resolver shim is not needed here: the library's resolver references
are versioned (`__dn_expand@GLIBC_2.2.5` etc. — check with
`readelf --dyn-syms`), which every later glibc still provides.

The library keeps ~15 undefined C++ runtime references (`__cxa_*`,
`_ZSt*`): the loading process must have `libstdc++.so.6` available at
runtime. It is present on any system with a C++ toolchain or runtime
installed; minimal containers may need `libstdc++6` (deb) /
`libstdc++` (rpm).

Both variants are non-thread-safe (NTS): one PHP engine per process, no
parallel requests in-process.
