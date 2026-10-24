# Docker systemd image

A family of base images — **Fedora 44**, **Debian 13 (trixie)**, **Ubuntu 26.04**,
and **Arch Linux** — that run **systemd as PID 1** and let you
choose a **custom default init target** and enable a set of **services** via
environment variables — no need to rebuild the image per deployment.

The entrypoint is a small, **extensible init framework** rather than a single
hard-coded script. It is designed to be used as the base of a family of
systemd images: a child image adds (or disables) **modules** and inherits the
same lifecycle, logging, and hook behaviour.

## Project layout

```
.
├── Dockerfile.fedora-44       # fedora:44 + systemd + dbus-broker + dbus-daemon + polkit
├── Dockerfile.debian-13       # debian:13 (trixie) + systemd + dbus-broker + dbus-daemon
├── Dockerfile.ubuntu-26.04    # ubuntu:26.04 + systemd + dbus-broker + dbus-daemon + polkitd
├── Dockerfile.archlinux       # archlinux:latest + systemd + dbus + polkit
├── .dockerignore
├── init.d/
│   ├── init.sh                # entrypoint: loads common/ + modules/ in order
│   ├── common/                # shared helpers (loaded first, every container)
│   │   ├── 000-hooks.sh       #   pre/post module hooks
│   │   ├── 001-bool.sh        #   is_true / is_false
│   │   ├── 002-init.sh        #   init_module_name (filename → function name)
│   │   ├── 003-print.sh       #   debug / info / warn / error / die + INIT_LOG_LEVEL
│   │   └── 004-systemd.sh     #   unit-name normalisation + resolve_unit
│   └── modules/               # one file per init phase (loaded + run in order)
│       ├── 501-systemd.sh     #   configure default.target / .wants (systemd)
│       └── 999-exec.sh        #   hand over PID 1: exec "$@"
├── test/                      # test suite + fixture units
└── .github/
    └── workflows/
        └── build-and-publish.yml   # CI: build, test, publish to GHCR
```

## How the init framework works

`init.sh` is the image entrypoint. It runs with `set -euo pipefail` and does
exactly three things:

1. **Load the shared helpers** — every `init.d/common/*.sh` file, in
   filename (sorted) order. These provide logging, boolean parsing, module
   naming, and systemd unit resolution. They are *sourced*, so all of their
   functions and hook registries are available to every module.
2. **Load the modules** — every `init.d/modules/*.sh` file, in filename order.
   The numeric prefix is the **ordering key**: lower runs first
   (`501-systemd` before `999-exec`). The prefix and extension are stripped and
   dashes become underscores, yielding the *module name*
   (`501-systemd.sh` → `systemd`, `999-exec.sh` → `exec`).
3. **Run the modules** in that same order. For each module it:
   - calls every registered **pre hook** — `hook pre <name>`;
   - asks `module_<name>_enabled` whether to run (a non-zero return skips it);
   - runs `module_<name>_run "$@"` (the original entrypoint arguments are
     forwarded to every module, so the final `exec` module receives them);
   - calls every registered **post hook** — `hook post <name>`.

Because the last module is `999-exec`, it terminates the container with
`exec "$@"` — by default `CMD ["/usr/sbin/init", "--system"]` — so **systemd
becomes PID 1** and receives signals such as `SIGRTMIN+3`
(`STOPSIGNAL SIGRTMIN+3`).

### The two built-in modules

| Module | Enabled when | What it does |
| --- | --- | --- |
| `systemd` (`501-systemd.sh`) | `MODULE_SYSTEMD_ENABLED` is true | Links `SYSTEMD_INIT_TARGET` as `default.target` and enables `SYSTEMD_INIT_TARGET_WANTS` into the `.wants` dirs. |
| `exec` (`999-exec.sh`) | always | `exec "$@"` — hands PID 1 to the `CMD` (systemd). |

### Module contract

Every module must provide two functions, named `module_<name>_…` where `<name>`
is the module name derived from the filename:

* `module_<name>_enabled` — `return 0` to run, non-zero to skip. (Convention:
  gate on a `MODULE_<NAME>_ENABLED` boolean.)
* `module_<name>_run [args…]` — the phase body. It runs in the init.sh shell,
  so it can define functions, set globals, and register hooks that later
  modules (or the next `run`) will see.

A module may also register **hooks** that fire around *other* modules:

```sh
add_module_pre_hook  my_pre_hook    # called as: my_pre_hook  pre <name>
add_module_post_hook my_post_hook   # called as: my_post_hook post <name>
```

The hook receives the phase (`pre`/`post`) and the name of the module it wraps,
so one hook can inspect/alter state for any module it targets.

### Logging

`003-print.sh` provides `debug`, `info`, `warn`, `error`, and `die` (which
prints a `[FATAL]` line and exits 1). Verbosity is controlled by
`INIT_LOG_LEVEL` (default `2`): `0` errors only, `1` +warnings, `2` +info,
`3` +debug. All output goes to **stderr**, so it survives being piped through
the container log driver and never pollutes stdout used by `exec`.

## Environment variables

| Variable | Default | Effect |
| --- | --- | --- |
| `MODULE_SYSTEMD_ENABLED` | `false` | Gate for the `systemd` module. Set to `true` (or `1`/`yes`/`on`) to configure init. |
| `SYSTEMD_INIT_TARGET` | — | Unit to boot as the default target. Linked to `/etc/systemd/system/default.target`. A missing `.target` extension is assumed. |
| `SYSTEMD_INIT_TARGET_WANTS` | — | Comma- and/or space separated list of services to enable into `default.target.wants/`. A missing `.service` extension is assumed. Unknown units are skipped with a warning. |
| `SYSTEMD_SYSTEM_DIR` | `/etc/systemd/system` | Base dir for the symlinks above (overridable for tests). |
| `DEFAULT_TARGET_LINK` | `$SYSTEMD_SYSTEM_DIR/default.target` | Where the default-target symlink is written. |
| `INIT_LOG_LEVEL` | `2` | `0` errors, `1` +warn, `2` +info, `3` +debug. |

`SYSTEMD_INIT_TARGET` and `SYSTEMD_INIT_TARGET_WANTS` each accept a bare name
(`mysvc`), a full unit name (`mysvc.target` / `mysvc.service`), or an absolute
path to a unit file.

> **Note:** when `SYSTEMD_INIT_TARGET` points at a custom target, the `systemd`
> module also mirrors the `SYSTEMD_INIT_TARGET_WANTS` symlinks into
> `<custom>.target.wants/` so the units are guaranteed to start regardless of
> which target is active.

## Build

Each distro has its own Dockerfile following the same shape as
`Dockerfile.fedora-44`:

| Distro | Base image | Install command |
| --- | --- | --- |
| Fedora | `fedora:44` | `dnf install systemd dbus-broker dbus-daemon polkit` |
| Debian | `debian:13` (trixie) | `apt-get install systemd dbus-broker dbus-daemon ca-certificates` |
| Ubuntu | `ubuntu:26.04` | `apt-get install systemd dbus-broker dbus-daemon polkitd ca-certificates` |
| Arch | `archlinux:latest` | `pacman -S systemd dbus polkit` (systemd ships in base) |

Build any one (or all):

```sh
# Fedora
docker build -f Dockerfile.fedora-44    -t skynet-systemd:fedora-44    .
# Debian
docker build -f Dockerfile.debian-13    -t skynet-systemd:debian-13    .
# Ubuntu
docker build -f Dockerfile.ubuntu-26.04 -t skynet-systemd:ubuntu-26.04 .
# Arch
docker build -f Dockerfile.archlinux    -t skynet-systemd:archlinux    .
```

All builds work the same with podman (`podman build -f … .`).

## Run

You must mount your own systemd unit files into `/etc/systemd/system` (they must
exist in the container for the entrypoint to resolve them), then pass the two
env vars. `--privileged --ipc=host` (plus `/dev/shm` / cgroup access as needed)
is required for systemd to manage services inside the container.

Example — boot `myapp.target` and start two services with it:

```sh
docker run --rm -it \
  --privileged --ipc=host \
  -v ./units:/etc/systemd/system:ro \
  -e SYSTEMD_INIT_TARGET=myapp.target \
  -e SYSTEMD_INIT_TARGET_WANTS="svc-a.service,svc-b.service" \
  skynet-systemd:latest
```

Same thing with podman:

```sh
podman run --rm -it \
  --privileged --ipc=host \
  -v ${PWD}/units:/etc/systemd/system:ro \
  -e SYSTEMD_INIT_TARGET=myapp.target \
  -e SYSTEMD_INIT_TARGET_WANTS="svc-a.service svc-b.service" \
  skynet-systemd:latest
```

Once running you can interact with it as usual:

```sh
systemctl status
systemctl list-units --type=service
journalctl -xe
```

## Example units

`units/myapp.target`

```ini
[Unit]
Description=My application target
After=network.target
```

`units/svc-a.service`

```ini
[Unit]
Description=Service A
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/my-app-a
Restart=on-failure
```

## Tests

A complete test suite lives in `test/` and proves that:

1. The `systemd` module creates the `default.target` symlink for
   `SYSTEMD_INIT_TARGET`.
2. `SYSTEMD_INIT_TARGET_WANTS` symlinks are created in `default.target.wants`
   (and the custom target's own `.wants` dir).
3. systemd actually **activates** the custom target **and** starts the wanted
   services (verified in a live container with `systemctl is-active`).
4. Bare names (no extension) and both comma- and space-separated lists work.
5. An unknown target fails fast with a clear error (container exits non-zero).
6. An unknown wanted service is skipped with a warning while the rest still boot.

Run all tests (defaults to Fedora):

```sh
bash test/test.sh
```

Run a specific distro:

```sh
DOCKERFILE=$PWD/Dockerfile.ubuntu-26.04 IMAGE_TAG=skynet-systemd:ubuntu-26.04 bash test/test.sh
```

Useful options:

| Env var | Default | Purpose |
| --- | --- | --- |
| `RUNTIME` | `docker` | `podman` to test against podman instead. |
| `DOCKERFILE` | `Dockerfile.fedora-44` | Path to the distro's Dockerfile. |
| `IMAGE_TAG` | `systemd:local-test` | Local tag to build/test. |
| `SKIP_BUILD` | `false` | `true` to skip the build step (image already exists). |
| `WAIT_TIMEOUT` | `90` | Seconds to wait for the target to become active. |

The harness uses `docker/podman run --privileged --ipc=host` (as requested),
mounts the fixture units into `/etc/systemd/system`, starts each container
detached, waits for the target to become active, runs `test/verify.sh` inside
the live container to assert target + service + symlink state, and always tears
the container down. A final summary reports pass/fail counts.

### Test fixtures

* `test/skynet-custom.target` — the custom init target.
* `test/skynet-svc-one.service`, `test/skynet-svc-two.service` — long-running
  fixture services used to prove `SYSTEMD_INIT_TARGET_WANTS`.
* `test/verify.sh` — in-container assertions (run via `docker/podman exec`).
* `test/host_verify_links.sh` — optional host-side symlink inspection helper.

## CI / Publishing

`.github/workflows/build-and-publish.yml` builds, tests, and publishes all four
distro images to the repository's GitHub Container Registry (GHCR) on every
push to `main` (and tag pushes):

```
ghcr.io/skynet-core/systemd:fedora-44
ghcr.io/skynet-core/systemd:debian-13
ghcr.io/skynet-core/systemd:ubuntu-26.04
ghcr.io/skynet-core/systemd:archlinux
ghcr.io/skynet-core/systemd:main      (branch tag)
ghcr.io/skynet-core/systemd:sha-…     (commit tag)
```

Pull requests run the full build + test matrix but **do not** push (GHCR write
requires `packages:write`, which PRs don't get). Use `docker/login-action` with
`ghcr.io` and your GHCR credentials to pull a published image:

```sh
docker pull ghcr.io/skynet-core/systemd:ubuntu-26.04
docker run --rm -it --privileged --ipc=host ghcr.io/skynet-core/systemd:ubuntu-26.04
```

