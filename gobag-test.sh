#!/usr/bin/env bash
#
# gobag-test.sh - prove a gobag.sh install works end to end:
# build an image in-cluster with devspace, push it to the registry, then pull
# it back as a pod.

set -euo pipefail

GOBAG_NAMESPACE="gobag"
GOBAG_RELEASE="zot"
GOBAG_REGISTRY_PORT="30500"
REGISTRY="${GOBAG_RELEASE}.${GOBAG_NAMESPACE}.svc.cluster.local:${GOBAG_REGISTRY_PORT}"
REGISTRIES_YAML="/etc/rancher/k3s/registries.yaml"

if [[ -t 1 ]]; then
	C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
else
	C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""
fi

say() { printf '%s\n' "$*"; }
die() { printf '\n%s[FATAL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

registry_endpoint() {
	local ip
	ip=$(kubectl -n "$GOBAG_NAMESPACE" get svc "$GOBAG_RELEASE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
	[[ -n "$ip" && "$ip" != "None" ]] || return 1
	printf 'http://%s:%s' "$ip" "$GOBAG_REGISTRY_PORT"
}

kubectl cluster-info >/dev/null 2>&1 || die "no reachable cluster; run './gobag.sh install' first."
endpoint=$(registry_endpoint) || die "no registry Service ${GOBAG_RELEASE} in namespace ${GOBAG_NAMESPACE}; run './gobag.sh install' first."
curl -fsS --max-time 5 "${endpoint}/v2/" >/dev/null 2>&1 || die "registry not reachable at ${endpoint}; run './gobag.sh install' first."
have devspace || die "devspace is not installed; run './gobag.sh install' first."

command_key=""
if have docker && docker buildx version >/dev/null 2>&1; then
	:
elif have buildx; then
	command_key=$'\n      command: ["buildx"]'
else
	die "buildx is not installed; run './gobag.sh install' first."
fi

image="${REGISTRY}/gobag-test:latest"
pod="gobag-test-$$"
work=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$work'; kubectl -n '$GOBAG_NAMESPACE' delete pod '$pod' --ignore-not-found --wait=false >/dev/null 2>&1 || true" EXIT

cat > "${work}/Dockerfile" <<-'EOF'
	FROM busybox:stable
	RUN echo gobag > /gobag-test
	CMD ["sh", "-c", "cat /gobag-test && sleep 3600"]
EOF

cat > "${work}/devspace.yaml" <<-EOF
	version: v2beta1
	name: gobag-test
	images:
	  test:
	    image: ${REGISTRY}/gobag-test
	    tags: ["latest"]
	    dockerfile: ./Dockerfile
	    context: ./
	    buildKit:${command_key}
	      args: ["--output", "type=image,push=true,registry.insecure=true"]
	      inCluster:
	        namespace: ${GOBAG_NAMESPACE}
	localRegistry:
	  enabled: false
EOF

say "${C_BOLD}Testing build -> push -> pull against ${REGISTRY}${C_RESET}"

say ""
say "  1/3 building in-cluster and pushing"
# --skip-push-local-kube defaults to true, which skips the push on a cluster
# devspace considers local.
( cd "$work" && devspace build \
	--namespace "$GOBAG_NAMESPACE" \
	--skip-push-local-kube=false \
	--no-warn ) ||
	die "the in-cluster build/push failed."

say "  2/3 confirming the push landed in the registry catalog"
catalog=$(curl -fsS "${endpoint}/v2/_catalog" 2>/dev/null || true)
printf '%s' "$catalog" | grep -q "gobag-test" ||
	die "the image is not in the registry catalog. Got: ${catalog:-<empty>}"
say "      catalog: ${catalog}"

say "  3/3 pulling it back as a pod (exercises the containerd mirror)"
kubectl -n "$GOBAG_NAMESPACE" run "$pod" --image="$image" \
	--image-pull-policy=Always --restart=Never >/dev/null
if ! kubectl -n "$GOBAG_NAMESPACE" wait --for=condition=Ready "pod/$pod" --timeout=120s >/dev/null 2>&1; then
	say ""
	kubectl -n "$GOBAG_NAMESPACE" describe pod "$pod" | sed -n '/Events:/,$p' | sed 's/^/      /'
	die "the pod never became Ready, so containerd could not pull ${image}. Check the ${REGISTRIES_YAML} mirror and that k3s was restarted after it changed."
fi

say ""
say "  ${C_GREEN}${C_BOLD}All three stages passed.${C_RESET} Image built in-cluster, pushed to Zot, and pulled back by containerd."
