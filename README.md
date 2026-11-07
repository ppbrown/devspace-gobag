# devspace-gobag

One-shot setup of a local Kubernetes dev environment for devspace, on Linux or WSL.

`gobag.sh install` sets up the following, installing only what's missing:

* A single-node k3s cluster, usable with plain `kubectl` (no sudo)
* helm, devspace, and buildx (which devspace uses to build images in-cluster)
* An in-cluster container registry at `zot.gobag.svc.cluster.local:30500`

## Install

```bash
./gobag.sh check      # optional: see what's already there
./gobag.sh install    # idempotent; safe to re-run
./gobag-test.sh       # optional: prove it actually works
```

`install` calls `sudo` for a few steps.

`check` only looks at whether things are installed and configured. `gobag-test.sh` actually uses
them: it builds a tiny test image with devspace in the cluster, pushes it to the registry, then runs
it as a pod so that the cluster has to pull it back. If that passes, `devspace build` and deploying
the result will work for your own projects. If it fails, it tells you which step broke. It leaves
behind a `gobag-test` image in the registry; the test pod is deleted.

**WSL:** gobag needs systemd and WSL's NAT networking mode. If either isn't set, `install` offers to
set it and stops. Run `wsl --shutdown` from Windows, reopen the distro, and run `./gobag.sh install`
again.

## Use it in a project

Copy `examples/devspace.yaml` into your project, change `name:` and `images.app.image`, then:

```bash
devspace build
```

The registry is already set in that file; no `devspace init` needed. `devspace_test/` is a working
example.

## Uninstall

```bash
./gobag.sh uninstall    # asks before removing k3s; -y to skip the question
```

For options, troubleshooting, and what gets changed on your system, see
[CUSTOMIZATION.md](CUSTOMIZATION.md).
