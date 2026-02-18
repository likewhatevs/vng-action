# virtme-ng Action

Run CI workloads inside a [virtme-ng](https://github.com/arighi/virtme-ng) VM with a specific kernel version. The host filesystem is visible read-only inside the VM, with `$GITHUB_WORKSPACE` mounted read-write so builds and tests write directly to the runner's disk.

## Quick Start

```yaml
steps:
  - uses: actions/checkout@v4
  - uses: likewhatevs/vng-action@v1
    with:
      name: mainline
      kernel-url: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
      kernel-tag: v6.12
      run: uname -r
```

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `name` | Yes | | Name for the kernel build cache (also embedded in `uname -r`) |
| `kernel-url` | Yes | | Git repository URL for the kernel source |
| `kernel-tag` | Yes | | Git tag or branch to checkout |
| `version` | No | `v2` | Cache version string — bump to force a rebuild |
| `kconfig` | No | | Path to a kconfig fragment file (relative to repo root) |
| `cpus` | No | all host CPUs | Number of CPUs for the VM |
| `memory` | No | 90% of host RAM (capped at 4G on ARM64) | Memory for the VM (e.g., `4G`, `512M`) |
| `network` | No | | Network mode for the VM (e.g., `user`) |
| `verbose` | No | `true` | Enable verbose vng boot output |
| `cc` | No | | C compiler for the kernel build (e.g., `clang`) |
| `llvm` | No | | Use full LLVM toolchain (`1` or `-14` for versioned) |
| `kernel-compile-cache` | No | `true` | Use ccache to speed up kernel rebuilds on cache miss |
| `append` | No | `mitigations=off` | Additional kernel boot parameters passed to vng via `--append` |
| `qemu-opts` | No | `-cpu host` (dropped on ARM64) | Additional QEMU options passed to vng via `--qemu-opts` |
| `deps-timeout` | No | `90` | Timeout in seconds for dependency installation (per attempt) |
| `deps-retries` | No | `3` | Number of retry attempts for dependency installation |
| `run-timeout` | No | `0` | Timeout in seconds for the VM workload (`0` = no timeout) |
| `packages` | No | | Extra apt packages to install and cache alongside vng dependencies (space-separated) |
| `install-recommends` | No | `false` | Install recommended packages alongside dependencies |
| `extra-rwdirs` | No | `~/.cargo` | Additional host directories to mount read-write in the VM (space-separated, tilde-expanded) |
| `run` | Yes | | Commands to execute inside the VM |

## Outputs

| Output | Description |
|--------|-------------|
| `kernel-sha` | Short commit SHA (12 chars) of the resolved kernel commit |

## How It Works

1. **Install** — restores cached apt packages, then installs kernel build toolchain, QEMU, ccache, virtme-ng, and any extra `packages` via apt. Saves the apt cache before proceeding. Skips installation if all packages are already present. Configures KVM access on CI runners.
2. **Resolve** — checks for a SHA cached by a prior job in this workflow run (scoped to `run_id`). On miss, resolves `kernel-tag` to a commit SHA via `git ls-remote` and saves it for subsequent jobs. If the remote is unreachable (e.g., kernel.org outage), falls back to the most recent cached kernel build for this name (see below).
3. **Cache** — checks for a cached kernel build keyed on `{name}-{sha}-{version}`. On hit, the build step is skipped entirely. The cache is shared across all jobs in the repository.
4. **Build** (cache miss only) — shallow-clones the kernel repo and runs `vng --build` to compile a minimal kernel. Uses ccache when `kernel-compile-cache` is enabled (default). Sets `LOCALVERSION` so `uname -r` includes the build name and commit SHA (e.g., `6.12.0__myproject__abc123def456`).
5. **Run** — boots the kernel in a QEMU VM via virtme-ng. Your `run` commands execute inside the VM with the working directory set to `$GITHUB_WORKSPACE`.

The VM shares the runner's filesystem via virtiofs. `$GITHUB_WORKSPACE` and any `extra-rwdirs` are mounted read-write so builds, test artifacts, and caches write directly to the runner's disk. Other paths use virtme-ng's default tmpfs overlays (writable but bounded by VM memory). The runner's environment is propagated into the VM.

## Examples

### With a custom kconfig

```yaml
- uses: likewhatevs/vng-action@v1
  with:
    name: myproject
    kernel-url: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
    kernel-tag: v6.12
    kconfig: ci/kernel.config
    run: make test
```

### Multiple kernels in one job

```yaml
- uses: likewhatevs/vng-action@v1
  with:
    name: stable
    kernel-url: https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
    kernel-tag: v6.6.50
    run: make test

- uses: likewhatevs/vng-action@v1
  with:
    name: mainline
    kernel-url: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
    kernel-tag: v6.12
    run: make test
```

### ARM64

```yaml
jobs:
  test:
    runs-on: ubuntu-24.04-arm
    steps:
      - uses: actions/checkout@v4
      - uses: likewhatevs/vng-action@v1
        with:
          name: mainline-arm
          kernel-url: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
          kernel-tag: v6.12
          run: uname -m
```

### Build once, test across parallel jobs

A large runner resolves the tag and builds the kernel. Subsequent jobs with the same `name` automatically pick up the resolved SHA and hit the kernel build cache — no extra wiring needed. Build and test jobs must use the same runner architecture family (kernel caches are scoped by `runner.arch`).

```yaml
jobs:
  build-kernel:
    runs-on: ubuntu-latest-16-cores
    steps:
      - uses: actions/checkout@v4
      - uses: likewhatevs/vng-action@v1
        with:
          name: sched-ext
          kernel-url: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
          kernel-tag: main
          run: uname -r

  test:
    needs: build-kernel
    strategy:
      matrix:
        suite: [test-rusty, test-lavd, test-bpfland]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: likewhatevs/vng-action@v1
        with:
          name: sched-ext
          kernel-url: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
          kernel-tag: main
          run: make ${{ matrix.suite }}
```

### Extra apt packages

Install and cache project-specific dependencies alongside vng's own — no separate apt caching step needed. Use a shared env var to keep the package set consistent across jobs so the apt cache covers everything.

```yaml
env:
  VNG_PACKAGES: clang-19 llvm-19 libelf-dev libseccomp-dev

jobs:
  build-kernel:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: likewhatevs/vng-action@v1
        with:
          name: mainline
          kernel-url: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
          kernel-tag: v6.12
          packages: ${{ env.VNG_PACKAGES }}
          run: uname -r

  test:
    needs: build-kernel
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: likewhatevs/vng-action@v1
        with:
          name: mainline
          kernel-url: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
          kernel-tag: v6.12
          packages: ${{ env.VNG_PACKAGES }}
          run: make test
```

### Stacking with other actions

Tools installed on the runner are visible inside the VM. `~/.cargo` is mounted read-write by default, so `cargo fetch` on the host populates the registry for in-VM builds.

```yaml
steps:
  - uses: actions/checkout@v4
  - uses: dtolnay/rust-toolchain@stable
  - uses: swatinem/rust-cache@v2
  - run: cargo fetch --locked
  - uses: likewhatevs/vng-action@v1
    with:
      name: mainline
      kernel-url: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
      kernel-tag: v6.12
      run: cargo test
```

## Cache Management

Four cache layers work together:

1. **Apt cache** (`vng-apt-{runner.arch}-{run_id}`) — caches downloaded `.deb` packages, scoped by runner architecture. Saved after dependency installation but before the kernel build or workload, so a workload failure cannot prevent the save. On restore, falls back to the most recent prior run's cache via prefix match. The first job in a run to save wins — to cache a unified package set across jobs, pass the same `packages` input to all vng-action calls (e.g., via a shared env var).
2. **SHA cache** (`vng-sha-{name}-{kernel-tag}-{run_id}`) — propagates the resolved commit SHA across jobs in the same workflow run. The first job resolves the tag and saves the SHA; subsequent jobs restore it automatically.
3. **Kernel build cache** (`vng-kernel-{name}-{runner.arch}-{sha}-{version}`) — stores the compiled kernel tree, scoped by runner architecture and shared across all jobs and runs in the repository.
4. **ccache** (`vng-ccache-{runner.arch}-{run_id}`) — compiler cache scoped by runner architecture, shared across all kernel builds in a workflow run. On cache miss, restores the most recent ccache from any prior run. Capped at 5 GB.

- **Same `name` across jobs** → same kernel, automatically
- **Bump `version`** → forces a rebuild (e.g., after changing kconfig)
- **Different `kernel-tag` resolving to a new SHA** → new cache entry
- **Set `kernel-compile-cache: false`** → disables ccache
- **Remote unreachable** → restores the most recent cached kernel build matching `vng-kernel-{name}-` and emits a warning. Fails only if no cached build exists at all.

## Supported Runners

| Runner | Arch | Status |
|--------|------|--------|
| `ubuntu-22.04`, `ubuntu-24.04` | x86_64 | Supported |
| `ubuntu-22.04-arm`, `ubuntu-24.04-arm` | ARM64 | Supported |

KVM must be available on the runner for reasonable performance. GitHub-hosted x86 Linux runners have KVM enabled by default. ARM64 runners currently lack KVM, so the VM falls back to software emulation (TCG) — memory is capped at 4G and `-cpu host` is stripped from `qemu-opts` automatically.

## License

[GPL-2.0](LICENSE)
