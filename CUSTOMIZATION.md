# Customization and troubleshooting

## Options

```
-n, --dry-run    show what would happen; never calls sudo
-y, --yes        don't prompt (uninstall otherwise asks before removing k3s
                 and before deleting stored images)
-q, --quiet      only print warnings and errors
-h, --help       show usage
```

## The registry address

The registry is `zot.gobag.svc.cluster.local:30500` from everywhere: build pods (cluster DNS), the
node's containerd (a mirror in `/etc/rancher/k3s/registries.yaml` pointing at the Service's
ClusterIP), and your host (an `/etc/hosts` line). Use that same string in your pod specs.

`localhost:30500` does **not** work; current kube-proxy doesn't serve NodePorts on loopback.

The registry is plain HTTP with no auth. It's meant for a single-user dev machine only.

## Keep these in your devspace.yaml

If you write your own `devspace.yaml` rather than copying the example, keep:

* `localRegistry: enabled: false` — otherwise devspace deploys its own registry and silently
  rewrites image names to `localhost:<nodeport>`, bypassing Zot.
* `buildKit.args: ["--output", "type=image,push=true,registry.insecure=true"]` — the registry is
  plain HTTP, and without this the push fails with `http: server gave HTTP response to HTTPS client`.
* `buildKit.inCluster: namespace: gobag` — builds in-cluster, using the `devspace-gobag` builder
  `install` created there. All your projects share it.

## No Docker needed

Builds run in-cluster via BuildKit. If you have neither Docker nor the buildx plugin, gobag installs
the standalone `buildx` binary; `examples/devspace.yaml` sets `buildKit.command: ["buildx"]` so
devspace uses it. If you do have `docker buildx`, you can drop that line.

## Existing clusters

If `kubectl` already reaches a cluster, gobag uses it instead of installing k3s, but only if it's
single-node and on this machine. Otherwise it refuses: the containerd mirror is configured only on
this machine, so other nodes couldn't pull your images.

## Troubleshooting

Start with `./gobag.sh check`. Re-running `./gobag.sh install` fixes most drift.

**`ImagePullBackOff` with `lookup zot.gobag.svc.cluster.local: no such host`** — the containerd
mirror is missing or points at an old ClusterIP (e.g. the registry Service was recreated). Re-run
`install`.

**`http: server gave HTTP response to HTTPS client`** — on push, your `devspace.yaml` is missing the
`registry.insecure=true` output arg. On pull, the `registries.yaml` endpoint lost its `http://`;
re-run `install`.

**Build succeeds but the image never lands in the registry** — devspace skips pushes when it thinks
the cluster is local, based on the kube-context name. The default k3s context (`default`) isn't
matched, but if you renamed it to something like `minikube`, `kind-*` or `docker-desktop`, pass
`--skip-push-local-kube=false`.

**Why WSL must use NAT networking** — with `networkingMode=mirrored`, WSL drops outbound traffic
from pods ([microsoft/WSL#11819](https://github.com/microsoft/WSL/issues/11819)), so builds can't
fetch base images and your pods can't reach the internet. `install` offers to switch it to `nat`.

**Registry name stops resolving on the host after a WSL reboot** — `install` sets
`generateHosts = false` in `/etc/wsl.conf` to prevent this; check that it's still there.

## What gets changed

| Path | What |
|---|---|
| `~/.local/bin/` | `helm`, `buildx`, `devspace` (only if missing) |
| `$KUBECONFIG` (default `~/.kube/config`) | written from k3s's kubeconfig, only if it doesn't exist |
| `~/.docker/cli-plugins/docker-buildx` | symlink to `buildx`, only if gobag installed it and the docker CLI exists |
| helm repos | `project-zot` |
| `/etc/rancher/k3s/registries.yaml` | containerd mirror entry (backed up first) |
| `/etc/hosts` | one line tagged `# gobag` (backed up to `/etc/hosts.gobag-bak` when an old entry is replaced or removed) |
| `/etc/wsl.conf` | WSL only: `systemd=true`, `generateHosts=false` (backed up first) |
| `%USERPROFILE%\.wslconfig` | WSL only: `networkingMode=nat`, if it was `mirrored` (backed up first) |
| cluster | namespace `gobag`: Zot release and the `devspace-gobag` BuildKit builder |

`uninstall` reverses all of it except `/etc/wsl.conf` and `.wslconfig`, and leaves the `.gobag-*`
backup files in place. When k3s is removed (or already gone), it also deletes the kubeconfig if
that file only holds the local k3s cluster; a file with other clusters in it is left alone.
