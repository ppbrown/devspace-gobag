# devspace_test

A deliberately trivial app, just to have something real to build and deploy against the registry
`gobag.sh` sets up.

Serves one page at `/`: title and body "dev demo". Set `BODY_CONTENTS` to append arbitrary text to
the body - useful for proving a deploy actually picked up a new env var / rollout.

## Run it directly

```bash
python3 app.py                        # -> http://localhost:8080, body "dev demo"
BODY_CONTENTS="hello" python3 app.py  # -> body "dev demo<br>hello"
```

## Use it with devspace

`devspace.yaml` is already here, pointing at the registry gobag.sh deploys:

```bash
cd devspace_test
devspace build     # builds in-cluster, pushes to the gobag registry
```

This repo doesn't ship a `deployments:`/`dev:` section - add one (or run `devspace init` to let it
scaffold one) when you're ready for `devspace dev`/`devspace deploy` to actually run the container.
`devspace init` will find `devspace.yaml` already has an `images:` entry and shouldn't re-ask about
the registry.
