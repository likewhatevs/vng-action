# virtme-ng Action

Run CI workloads inside a [virtme-ng](https://github.com/arighi/virtme-ng) VM with a specific kernel version. The host filesystem is mounted as a copy-on-write overlay — the VM can read everything on the runner but cannot mutate it.

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
| `name` | Yes | | Name for the kernel build cache |
| `kernel-url` | Yes | | Git repository URL for the kernel source |
| `kernel-tag` | Yes | | Git tag or branch to checkout |
| `version` | No | `v1` | Cache version string — bump to force a rebuild |
| `kconfig` | No | | Path to a kconfig fragment file (relative to repo root) |
| `cpus` | No | all available | Number of CPUs for the VM |
| `memory` | No | QEMU default | Memory for the VM (e.g., `4G`, `512M`) |
| `run` | Yes | | Commands to execute inside the VM |

## Outputs

| Output | Description |
|--------|-------------|
| `kernel-sha` | Short commit SHA (12 chars) of the resolved kernel commit |

## How It Works

1. **Install** — installs kernel build toolchain, QEMU, and virtme-ng via apt. Skips if already present. Configures KVM access on CI runners.
2. **Resolve** — checks for a SHA cached by a prior job in this workflow run (scoped to `run_id`). On miss, resolves `kernel-tag` to a commit SHA via `git ls-remote` and saves it for subsequent jobs.
3. **Cache** — checks for a cached kernel build keyed on `{name}-{sha}-{version}`. On hit, the build step is skipped entirely. The cache is shared across all jobs in the repository.
4. **Build** (cache miss only) — shallow-clones the kernel repo and runs `vng --build` to compile a minimal kernel.
5. **Run** — boots the kernel in a QEMU VM via virtme-ng. Your `run` commands execute inside the VM with the working directory set to `$GITHUB_WORKSPACE`.

The VM uses virtme-ng's default copy-on-write overlay: the entire host filesystem is visible inside the VM, but all writes go to a tmpfs overlay and do not persist back to the host.

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

### Custom CPU and memory

```yaml
- uses: likewhatevs/vng-action@v1
  with:
    name: mainline
    kernel-url: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
    kernel-tag: v6.12
    cpus: 4
    memory: 8G
    run: make test
```

### Build once, test across parallel jobs

A large runner resolves the tag and builds the kernel. Subsequent jobs with the same `name` automatically pick up the resolved SHA and hit the kernel build cache — no extra wiring needed.

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

### Stacking with other actions

Tools installed on the runner are visible inside the VM.

```yaml
steps:
  - uses: actions/checkout@v4
  - uses: dtolnay/rust-toolchain@stable
  - uses: likewhatevs/vng-action@v1
    with:
      name: mainline
      kernel-url: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
      kernel-tag: v6.12
      run: cargo test
```

## Cache Management

Two cache layers work together:

1. **SHA cache** (`vng-sha-{name}-{kernel-tag}-{run_id}`) — propagates the resolved commit SHA across jobs in the same workflow run. The first job resolves the tag and saves the SHA; subsequent jobs restore it automatically.
2. **Kernel build cache** (`vng-kernel-{name}-{sha}-{version}`) — stores the compiled kernel tree, shared across all jobs and runs in the repository.

- **Same `name` across jobs** → same kernel, automatically
- **Bump `version`** → forces a rebuild (e.g., after changing kconfig)
- **Different `kernel-tag` resolving to a new SHA** → new cache entry

## Supported Runners

| OS | Status |
|----|--------|
| Ubuntu (22.04, 24.04) | Supported |

KVM must be available on the runner for reasonable performance. GitHub-hosted Linux runners have KVM enabled by default.

## License

[GPL-2.0](LICENSE)
