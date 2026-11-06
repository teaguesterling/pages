---
layout: base.njk
permalink: /spack-duckdb/
---

<article class="guide">

# DuckDB extensions with Spack

Spack can install DuckDB 2.0.0 extensions into a view, from a mirror, or built from source and
signed with your own key. This page explains how to use the packages and what each mode
trusts. The recipes are in four Spack pull requests:

| PR | Adds |
|---|---|
| [#7407](https://github.com/spack/spack-packages/pull/7407) | `duckdb` 1.5.4 to 2.0.0 |
| [#7443](https://github.com/spack/spack-packages/pull/7443) | extension search directories and signing key variants on `duckdb` |
| [#7442](https://github.com/spack/spack-packages/pull/7442) | the base class, the `duckdb-extensions` bundle and 23 core extensions |
| [#7444](https://github.com/spack/spack-packages/pull/7444) | 19 community extensions |

Each PR contains the PRs above it. Until they merge, use the branch of #7444.

## Quick start: a view with extensions

```yaml
# spack.yaml
spack:
  specs:
  - duckdb-extensions@2.0.0 +httpfs +fts +spatial
  view: true
```

```console
$ spack env activate .
$ spack install
$ duckdb -c "LOAD spatial; SELECT ST_AsText(ST_Point(1, 2));"
```

The bundle needs `duckdb+extension_env`. On activation, that variant sets
`DUCKDB_EXTENSION_DIRECTORIES` to the extension directory of the view, so DuckDB finds the
extensions there. Without a view, `spack load duckdb-extensions` sets the variable to each
extension prefix.

Each core extension is also a package of its own, such as `duckdb-httpfs`. Community
extensions are packages only, such as `duckdb-h3`. They are not variants of the bundle.

## Three ways to get an extension

| Spec | Source | What is checked |
|---|---|---|
| `@2.0.0` (default for core) | The published binary, as a Spack resource for each platform | sha256 by Spack, and the signature at each load |
| `@latest` (default for community) | `INSTALL` from DuckDB, during the install step | an HTTPS copy of the same file, and the signature |
| `+site_signed` | A pinned git commit of the extension, built against the DuckDB source | the signature with your key |

- `@2.0.0` works from a mirror with no network.
- `@latest` needs network access in the install step. Two installs of one spec can get different
  binaries. It does not protect against a bad binary at the origin.
- Community binaries change at the same URL. Of the 19 community extensions, 12 had a new
  binary after the 2.0.0 release. A recorded checksum then fails unless a mirror has the old
  binary. So community packages default to `@latest`.

## Signing keys

Stock DuckDB loads only extensions signed by the core or community keys. `duckdb` has two
variants that change this:

- `extension_keys=core,community,site` (default `core,community`): the keys to trust. The
  default applies no patch.
- `extension_key=<sha256>`: the public key to trust for `site`, as the sha256 of its DER
  form.

```console
$ openssl genrsa -out ext-key.pem 2048
$ openssl rsa -in ext-key.pem -pubout -out ext-pub.pem
$ openssl rsa -in ext-key.pem -pubout -outform DER | sha256sum
5a57d3e5...  -
```

The key must be RSA-2048, because a DuckDB signature has 256 bytes. The spec holds only the
sha256. The key files stay outside of the spec, the prefix and any build cache.

## Building from source with `+site_signed`

```console
$ export DUCKDB_EXTENSION_PUBLIC_KEY=$PWD/ext-pub.pem
$ export DUCKDB_EXTENSION_PRIVATE_KEY=$PWD/ext-key.pem
$ spack install duckdb-extensions@2.0.0 +site_signed +httpfs +fts \
    ^duckdb extension_keys=core,community,site extension_key=5a57d3e5...
```

- The build links `libduckdb_static.a` from the `duckdb` prefix, so DuckDB is not compiled again.
- Each C and C++ dependency of the extension comes from a static Spack package that the recipe
  declares. CMake does not look on the host, and a download during CMake fails.
- The Rust extensions (`delta`, `lance`, `vortex` and `rusty_sheet`) are different. Cargo
  downloads their crates from crates.io and git during the build, at the versions in
  `Cargo.lock`. The build cannot run with no network.
- Before signing, the install step checks the binary: it fails on any shared dependency other
  than the C and C++ runtime, and on any RUNPATH.
- The install step replaces store paths in the binary before it signs. A build cache otherwise
  rewrites them, and the signature becomes invalid.

**Trust.** The build runs as your user, so code that you build can obtain the private key. Thus
code that you build can sign other code that this DuckDB will load. Use one key for one level
of trust. A signer that build code cannot reach is planned, but not done.

## Air gap

- **Mirror:** `spack mirror create` with `@2.0.0` or `+site_signed` specs. Spack fetches the
  DuckDB source (102 MB) once for each mirror, because a resource needs a main archive.
- A mirror does not hold the crates of the Rust extensions. Build them on a connected host,
  and move them with a build cache.
- **Build cache:** build on a connected host, then install from the cache. Use
  `padded_length` for the dependencies.

## Status of `+site_signed`

Measured on `linux_amd64` with GCC 13.3. Other platforms were not loaded.

| | Core (23) | Community (19) |
|---|---|---|
| Pass in the open PRs | 11 | 9 |
| Pass with planned follow-up PRs | 23 | 18 |

A pass means all of these: the build ran with no network from fetched sources; the binary
loaded with no network; a DuckDB without the key refused it; and it loaded after a build cache
install of its whole dependency tree into an empty store with no network. The Rust extensions
are the exception to the first test: their builds had network access, for the crates.

The follow-up PRs add or update the static dependencies that these extensions need, such as
`croaring`, `minizip-ng`, `ada-url`, `cmark-gfm`, the Azure SDK, `aws-sdk-cpp`, `grpc` and
`gdal`. They also add `+site_signed` to the Rust extensions. The remaining extension is
`bigquery`.

## Known limits

- `nanoarrow` at `@2.0.0` has a RUNPATH, so a build cache install makes its signature invalid.
  `nanoarrow+site_signed` has no RUNPATH.
- `httpfs+site_signed` uses `curl~nghttp2`, so it has no HTTP/2.
- Most extensions were only loaded, not exercised.

</article>
