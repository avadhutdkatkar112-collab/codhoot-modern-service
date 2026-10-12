# codhoot-modern-service

Execution server for CodHoot's **modern and niche** languages — Forth, Zig,
Crystal, Dart, Objective-C, Verilog and VHDL. Each ships its own toolchain (a
compiler frontend, a simulator, or a single-binary release archive) but they
share one gcc base and one dispatch table.

Swift is deliberately **not** in this image — see below.

## Why this service exists

CodHoot's single-language services each hard-code one compiler and one entry
filename, so they cannot be reused for a language they were not built for. The
backend routes these languages here through the shared runtime image URL:

```
COMPILER_IMAGE_MODERN_SERVICE_URL=https://codhoot-modern-service-<suffix>.onrender.com
```

One variable covers all seven languages. The mapping is read at backend startup,
so set the variable and restart the backend service.

## Contract

`POST /compile`, signed with
`HMAC-SHA256(secret, timestamp + path + hex(sha256(body)))` keyed by
`CODHOOT_INTERNAL_SECRET`, headers `X-CodHoot-Timestamp` (unix seconds) and
`X-CodHoot-Signature` (hex digest). Unsigned, tampered or stale requests get
401.

```json
{ "language": "forth", "source": ": ok cr echo(\"hi\") cr bye\n" }
```

`GET /health` and `GET /health/live` are open — Render's health check and the
keepalive pinger must never need a signature.

| language   | entry file | compile                                           | run                     |
|------------|------------|---------------------------------------------------|-------------------------|
| crystal    | `main.cr`  | `crystal build --no-debug -o main {src}`          | `./main`                |
| dart       | `main.dart`| —                                                 | `dart {src}`            |
| forth      | `main.fth` | —                                                 | `gforth {src}`          |
| objectivec | `main.m`   | `clang {src} -o main -lobjc`                     | `./main`                |
| verilog    | `main.v`   | `iverilog -o main.vvp {src}`                      | `vvp main.vvp`          |
| vhdl       | `main.vhd` | `ghdl -a --std=08 {src}`                          | `ghdl -r --std=08 main` |
| zig        | `main.zig` | `zig build-exe {src} -O ReleaseSafe -femit-bin=main` | `./main`             |

Those command lines are the backend registry's own `CompileCommand` and
`RunCommand` for each language, so a job behaves identically to the local
`codhoot-runner-modern` docker path.

## Swift is not here (yet)

Swift's toolchain is ~700 MB unpacked and links against Debian's ICU, editline,
ncurses, sqlite3, xml2 and z3 development libraries, which pushes this image
well past what a free-tier Render instance will build or hold — and the whole
point of this image is that it deploys. Swift is the one language on
`codhoot-runner-modern` left without a service.

Two ways forward, in order of preference:

1. A separate `codhoot-swift-service` on a larger instance, routed with
   `COMPILER_SWIFT_SERVICE_URL` (the backend consults per-language URLs before
   image URLs, so this works regardless of this service existing).
2. Adding Swift to this image if Render's limits are raised.

Either way the backend needs no code change: Swift's routing today falls through
to the local docker path, which is the thing being removed.

## Toolchains

clang + gobjc/libobjc, gforth, iverilog and ghdl from Debian bookworm; Zig
0.13.0, Crystal 1.10.1 and Dart 3.13.5 as pinned release archives. Every
toolchain is smoke-tested during the image build — zig and crystal in particular
fail differently from how they are usually invoked, and finding that out at build
time is much cheaper than finding it out from a first submission.

## Deployment

Render blueprint: **New → Blueprint**, point it at this repo, apply. Set
`CODHOOT_INTERNAL_SECRET` to the same value the backend uses.

The service listens on `PORT` (Render sets it to 10000; the image default is
8081). `MAX_CONCURRENT_JOBS` defaults to 3.

## Sandbox

Each job gets its own uid from a 32-entry pool, a private random 0700 working
directory, a minimal environment, rlimits applied by a trampoline re-exec, and
process-group kill on timeout. The service runs as root only to chown and
setuid; the boundary is the child. See `harden.go` / `harden_unix.go`.