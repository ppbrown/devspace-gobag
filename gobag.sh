#!/usr/bin/env bash
#
# gobag.sh - one-shot setup of a local Kubernetes dev environment.
#
# Provides, idempotently:
#   - a single-node k3s cluster (if no local cluster is already reachable)
#   - sudo-less kubectl
#   - helm
#   - a Zot OCI registry in-cluster, reachable by one URL from host, node and pods
#   - devspace, and the buildx CLI it uses to build in-cluster
#
# See README.md for usage and CUSTOMIZATION.md for options and troubleshooting.
# Run './gobag.sh check' for status, or './gobag.sh install --dry-run' to see
# what it would change.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

GOBAG_NAMESPACE="gobag"
GOBAG_RELEASE="zot"
GOBAG_REGISTRY_PORT="30500"
# The name devspace gives the builder it creates in GOBAG_NAMESPACE.
GOBAG_BUILDER="devspace-gobag"
GOBAG_PVC_SIZE="8Gi"

REGISTRY_HOST="${GOBAG_RELEASE}.${GOBAG_NAMESPACE}.svc.cluster.local"
REGISTRY="${REGISTRY_HOST}:${GOBAG_REGISTRY_PORT}"

BIN_DIR="$HOME/.local/bin"

K3S_YAML="/etc/rancher/k3s/k3s.yaml"
REGISTRIES_YAML="/etc/rancher/k3s/registries.yaml"
KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/config}"

# Pinned fallbacks, used only when the version cannot be discovered at runtime.
HELM_FALLBACK_VERSION="v3.16.3"
BUILDX_FALLBACK_VERSION="v0.19.3"

DRY_RUN=0
ASSUME_YES=0
QUIET=0

# Mutable state.
BUILDX=()
# Scratch directory for generated config files, created in main and removed on exit.
WORK_DIR=""

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
	C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
	C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
	C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

say()  { (( QUIET )) || printf '%s\n' "$*"; }
head1() { (( QUIET )) || printf '\n%s==> %s%s\n' "$C_BOLD$C_BLUE" "$*" "$C_RESET"; }
act()  { (( QUIET )) || printf '  %s[DO]%s   %s\n' "$C_GREEN" "$C_RESET" "$*"; }
skip() { (( QUIET )) || printf '  %s[SKIP]%s %s\n' "$C_DIM" "$C_RESET" "$*"; }
info() { (( QUIET )) || printf '         %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
warn() { printf '  %s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '\n%s[FATAL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# Run a mutating command, honouring --dry-run.
run() {
	if (( DRY_RUN )); then
		printf '         %swould run: %s%s\n' "$C_DIM" "$*" "$C_RESET"
		return 0
	fi
	"$@"
}

# Run a mutating shell pipeline, honouring --dry-run.
run_sh() {
	if (( DRY_RUN )); then
		printf '         %swould run: %s%s\n' "$C_DIM" "$1" "$C_RESET"
		return 0
	fi
	bash -c "$1"
}

confirm() {
	(( ASSUME_YES )) && return 0
	(( DRY_RUN )) && return 1
	local reply
	read -r -p "  $1 [y/N] " reply </dev/tty || return 1
	[[ "$reply" == [yY]* ]]
}

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

arch() {
	case "$(uname -m)" in
		x86_64 | amd64) printf 'amd64' ;;
		aarch64 | arm64) printf 'arm64' ;;
		*) die "unsupported architecture: $(uname -m)" ;;
	esac
}

is_wsl() { grep -qi microsoft /proc/version 2>/dev/null; }

# Use sudo for commands that need root. Nothing fancy: sudo handles its own
# password prompting and credential caching the normal way, whenever a step
# that needs it actually runs.
need_sudo() {
	[[ "$(id -u)" == 0 ]] && { SUDO=""; return 0; }
	SUDO="sudo"
	if (( DRY_RUN )); then
		info "(this step needs sudo)"
		return 0
	fi
	have sudo || die "sudo is required for this step but is not installed."
}
SUDO=""

# Every IP address on this host, plus loopback names.
local_addresses() {
	printf '127.0.0.1\nlocalhost\n::1\n'
	if have ip; then
		ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1
	fi
	hostname -I 2>/dev/null | tr ' ' '\n' || true
}

is_local_address() {
	local candidate="$1" addr
	[[ -z "$candidate" ]] && return 1
	while read -r addr; do
		[[ -n "$addr" && "$addr" == "$candidate" ]] && return 0
	done < <(local_addresses)
	return 1
}

# Extract the host portion of a URL (strip scheme, port, path).
url_host() {
	local url="$1"
	url="${url#*://}"
	url="${url%%/*}"
	url="${url%%\?*}"
	# Strip a trailing :port, but leave bare IPv6 alone.
	if [[ "$url" != \[* ]]; then
		url="${url%%:*}"
	fi
	printf '%s' "$url"
}

latest_github_tag() {
	local repo="$1" fallback="$2" tag
	tag=$(curl -fsSL --max-time 10 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null |
		sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1) || true
	printf '%s' "${tag:-$fallback}"
}

# Wait until a command succeeds, or time out.
wait_for() {
	local desc="$1" timeout="$2"
	shift 2
	(( DRY_RUN )) && return 0
	local deadline=$(( SECONDS + timeout ))
	until "$@" >/dev/null 2>&1; do
		(( SECONDS >= deadline )) && { warn "timed out after ${timeout}s waiting for ${desc}"; return 1; }
		sleep 3
	done
	return 0
}

# The Service's ClusterIP is the address every consumer can actually reach:
#
#   - pods resolve the Service name to it via cluster DNS
#   - the host and the node's containerd share a network namespace in which
#     kube-proxy has programmed routes to it
#
# It is NOT 127.0.0.1. Modern kube-proxy no longer installs the localhost
# NodePort special case (that behaviour was deprecated and then removed), so a
# loopback NodePort times out even with route_localnet=1.
#
# The ClusterIP lives in etcd, so it is stable across reboots and k3s restarts.
# It only changes if the Service is deleted and recreated, which 'check' detects
# and a re-run of 'install' repairs.
registry_cluster_ip() {
	kubectl -n "$GOBAG_NAMESPACE" get svc "$GOBAG_RELEASE" \
		-o jsonpath='{.spec.clusterIP}' 2>/dev/null || true
}

registry_endpoint() {
	local ip
	ip=$(registry_cluster_ip)
	[[ -n "$ip" && "$ip" != "None" ]] || return 1
	printf 'http://%s:%s' "$ip" "$GOBAG_REGISTRY_PORT"
}

registry_reachable() {
	local ep
	ep=$(registry_endpoint) || return 1
	curl -fsS --max-time 5 "${ep}/v2/" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Embedded config fragments
# ---------------------------------------------------------------------------

zot_values() {
	cat <<-EOF
		# Managed by gobag.sh - do not edit by hand.
		#
		# fullnameOverride pins the Service name so the in-cluster DNS name is
		# deterministic: ${REGISTRY_HOST}
		fullnameOverride: ${GOBAG_RELEASE}

		# service.port and service.nodePort are both ${GOBAG_REGISTRY_PORT} so the registry
		# answers on the same port however it is reached: via the ClusterIP (which is
		# what build pods, the host and the node's containerd all use) or via the
		# NodePort on the node's own IP (a convenience, e.g. from another machine).
		# targetPort is the chart's named "zot" port, which tracks httpGet.port, so the
		# container itself keeps listening on its default 5000 and needs no config
		# override.
		service:
		  type: NodePort
		  port: ${GOBAG_REGISTRY_PORT}
		  nodePort: ${GOBAG_REGISTRY_PORT}

		# Persist the registry across restarts. This switches the chart to a
		# StatefulSet with a volumeClaimTemplate; k3s's default local-path
		# StorageClass satisfies the claim.
		persistence: true
		pvc:
		  create: true
		  accessModes: ["ReadWriteOnce"]
		  storage: ${GOBAG_PVC_SIZE}

		# No http.auth stanza: anonymous read/write. This is a single-user local dev
		# registry.
	EOF
}

GOBAG_MARKER="# Managed by gobag.sh - do not edit by hand."

# $1 = the endpoint URL containerd should dial for our registry name.
registries_yaml_stanza() {
	cat <<-EOF
		mirrors:
		  "${REGISTRY}":
		    endpoint:
		      - "${1}"
	EOF
}

# Idempotently ensure `key = value` is set under `[section]` in /etc/wsl.conf,
# inserting the section if it doesn't exist and replacing any existing value
# for that key. Used for the two WSL settings gobag needs automated so that
# nothing is left for the user to edit by hand: [boot] systemd=true (k3s
# requires it) and [network] generateHosts=false (otherwise WSL wipes the
# registry's /etc/hosts entry on every reboot).
ensure_wsl_conf_setting() {
	local section="$1" key="$2" value="$3" wanted="${2} = ${3}"
	local existing=""
	[[ -r /etc/wsl.conf ]] && existing=$(cat /etc/wsl.conf)

	if printf '%s\n' "$existing" | awk -v sec="[$section]" -v k="$key" -v v="$value" '
		$0 == sec { in_sec = 1; next }
		/^\[/     { in_sec = 0 }
		in_sec && $0 ~ "^[ \t]*" k "[ \t]*=[ \t]*" v "([ \t]*(#.*)?)?$" { found = 1 }
		END { exit !found }
	'; then
		return 0
	fi

	if (( DRY_RUN )); then
		info "would set '${key} = ${value}' under [${section}] in /etc/wsl.conf"
		return 0
	fi
	need_sudo

	local tmp backup
	tmp=$(mktemp)
	if [[ -n "$existing" ]]; then
		backup="/etc/wsl.conf.gobag-$(date +%Y%m%d%H%M%S).bak"
		$SUDO cp -p /etc/wsl.conf "$backup"
		info "existing /etc/wsl.conf backed up to ${backup}"
	fi

	if printf '%s\n' "$existing" | grep -qxF "[$section]"; then
		printf '%s\n' "$existing" | awk -v sec="[$section]" -v k="$key" -v line="$wanted" '
			BEGIN { in_sec = 0; placed = 0 }
			{
				if ($0 == sec) { print; in_sec = 1; next }
				if (in_sec && /^\[/ && !placed) { print line; placed = 1; in_sec = 0 }
				if (in_sec && $0 ~ "^[ \t]*" k "[ \t]*=") { next }
				print
			}
			END { if (in_sec && !placed) print line }
		' > "$tmp"
	else
		{ [[ -n "$existing" ]] && printf '%s\n' "$existing"; printf '\n[%s]\n%s\n' "$section" "$wanted"; } > "$tmp"
	fi

	act "set '${key} = ${value}' under [${section}] in /etc/wsl.conf"
	$SUDO install -m 644 "$tmp" /etc/wsl.conf
	rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

wsl_config_path() {
	local profile
	profile=$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r') || return 1
	[[ -n "$profile" ]] || return 1
	printf '%s/.wslconfig' "$(wslpath -u "$profile")"
}

wsl_networking_mode() {
	if have wslinfo; then
		wslinfo --networking-mode 2>/dev/null && return
	fi
	local cfg
	cfg=$(wsl_config_path) || { printf 'nat'; return; }
	if grep -qiE '^[[:space:]]*networkingMode[[:space:]]*=[[:space:]]*mirrored' "$cfg" 2>/dev/null; then
		printf 'mirrored'
	else
		printf 'nat'
	fi
}

# WSL's mirrored networking drops pods' outbound traffic (microsoft/WSL#11819),
# so builds cannot fetch base images and pods cannot reach the internet.
ensure_wsl_nat_mode() {
	local cfg
	cfg=$(wsl_config_path) ||
		die "WSL is using mirrored networking, which breaks pods' internet access. Set networkingMode=nat under [wsl2] in %USERPROFILE%\\.wslconfig on Windows, run 'wsl --shutdown', and re-run install."
	grep -qiE '^[[:space:]]*networkingMode[[:space:]]*=' "$cfg" 2>/dev/null ||
		die "WSL is using mirrored networking but ${cfg} has no networkingMode line to change. Set networkingMode=nat under [wsl2] there, run 'wsl --shutdown', and re-run install."

	if (( DRY_RUN )); then
		info "would set networkingMode=nat in ${cfg} (WSL's mirrored mode breaks pods' internet access)"
		return
	fi
	confirm "WSL's mirrored networking breaks pods' internet access. Set networkingMode=nat in ${cfg}? (applies to all WSL distros)" ||
		die "gobag needs WSL's NAT networking mode. Set networkingMode=nat in ${cfg}, run 'wsl --shutdown', and re-run install."

	local backup
	backup="${cfg}.gobag-$(date +%Y%m%d%H%M%S).bak"
	cp -p "$cfg" "$backup"
	info "existing .wslconfig backed up to ${backup}"
	act "set networkingMode=nat in ${cfg}"
	sed -i -E 's/^([[:space:]]*networkingMode[[:space:]]*=[[:space:]]*)[A-Za-z]+/\1nat/I' "$cfg"
}

preflight() {
	head1 "Preflight"

	[[ "$(uname -s)" == "Linux" ]] || die "gobag only supports Linux (native or WSL); found $(uname -s)."
	have curl || die "curl is required. Install it (e.g. 'sudo apt install curl') and re-run."

	if is_wsl; then
		# Both settings below only take effect after WSL restarts, which has to be
		# done from Windows. Make every change first, then stop once.
		local restart_needed=0

		if [[ "$(ps -p 1 -o comm= 2>/dev/null)" == "systemd" ]]; then
			skip "WSL detected, systemd is PID 1"
		else
			ensure_wsl_conf_setting boot systemd true
			restart_needed=1
		fi

		# WSL regenerates /etc/hosts on every boot, which would drop the registry
		# line install adds. Takes effect without a restart.
		ensure_wsl_conf_setting network generateHosts false

		if [[ "$(wsl_networking_mode)" == "mirrored" ]]; then
			ensure_wsl_nat_mode
			restart_needed=1
		else
			skip "WSL networking mode is NAT"
		fi

		if (( restart_needed && ! DRY_RUN )); then
			die "$(cat <<-EOF
			WSL settings were changed and only take effect after WSL restarts, which
			this script cannot do from inside WSL. From a Windows prompt:

			  wsl --shutdown

			then reopen this distro and re-run './gobag.sh install'.
			EOF
			)"
		fi
	else
		skip "native Linux"
	fi

	local cgroup_fs
	cgroup_fs=$(stat -fc %T /sys/fs/cgroup 2>/dev/null || true)
	if [[ "$cgroup_fs" == "cgroup2fs" ]]; then
		skip "cgroup v2"
	elif [[ -n "$cgroup_fs" ]]; then
		warn "cgroup v2 not detected (found '${cgroup_fs}'). k3s generally still works on cgroup v1, but if it fails to start this is the first thing to check."
	else
		die "no cgroup filesystem at /sys/fs/cgroup; k3s cannot run here."
	fi

	if [[ ! -d "$BIN_DIR" ]]; then
		act "create $BIN_DIR"
		run mkdir -p "$BIN_DIR"
	fi
	case ":$PATH:" in
		*":$BIN_DIR:"*) : ;;
		*) warn "$BIN_DIR is not on your PATH. Add it (e.g. in ~/.bashrc): export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
	esac
}

# Checks the kubeconfig file explicitly: k3s's kubectl otherwise falls back to
# /etc/rancher/k3s/k3s.yaml, which helm and devspace never read.
cluster_reachable() {
	have kubectl && kubectl --kubeconfig "$KUBECONFIG_PATH" cluster-info --request-timeout=5s >/dev/null 2>&1
}

# Refuse to proceed on a cluster this design cannot serve: the registry is
# reached via its Service's ClusterIP and mirrored via this machine's
# containerd config, so the single node has to be this machine.
assert_cluster_is_local() {
	local node_count
	node_count=$(kubectl get nodes --no-headers 2>/dev/null | grep -c . || true)
	if [[ "$node_count" != "1" ]]; then
		die "$(cat <<-EOF
		The reachable cluster has ${node_count} nodes, but gobag's registry design needs a
		single-node local cluster.

		The registry is reached through the zot Service's ClusterIP, which only the
		cluster's own nodes can route to, and the containerd mirror that points at it is
		written to this machine's k3s config. On a multi-node cluster only the node gobag
		configured could pull, so image pulls would fail on every other node.

		Point kubectl at a local single-node cluster (or unset KUBECONFIG so gobag can
		install k3s) and re-run.
		EOF
		)"
	fi

	local server host node_ip
	server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
	host=$(url_host "$server")
	node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)

	if is_local_address "$host" || is_local_address "$node_ip"; then
		skip "existing cluster is single-node and local (api: ${host:-?}, node: ${node_ip:-?})"
		return 0
	fi

	die "$(cat <<-EOF
	The reachable cluster does not look local (api server: ${host:-unknown}, node IP:
	${node_ip:-unknown}); neither address belongs to this machine.

	gobag points the node's containerd at the registry Service's ClusterIP, and writes
	that mirror into this machine's k3s config. On a remote cluster the build pods could
	push, but no node could pull the result, so gobag will not install a registry it
	knows cannot work.

	Point kubectl at a local cluster (or unset KUBECONFIG so gobag can install k3s)
	and re-run.
	EOF
	)"
}

ensure_cluster() {
	head1 "Kubernetes cluster"

	if cluster_reachable; then
		assert_cluster_is_local
		return
	fi

	if have k3s && systemctl is-active --quiet k3s 2>/dev/null; then
		info "k3s service is running but kubectl cannot reach it with the current kubeconfig."
		return
	fi

	act "install k3s (single node, --write-kubeconfig-mode 644)"
	info "no kubectl-reachable cluster found"
	need_sudo
	run_sh "curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='server --write-kubeconfig-mode 644' sh -"
	wait_for "k3s to become active" 120 systemctl is-active --quiet k3s ||
		die "k3s did not come up; check 'journalctl -u k3s -n 50'."
}

# Make kubectl work as this user. An existing kubeconfig is never modified.
ensure_kubeconfig() {
	head1 "kubeconfig"

	if cluster_reachable; then
		skip "kubectl already reaches the cluster as $(id -un) (no sudo needed)"
		return
	fi

	if (( DRY_RUN )) && [[ ! -r "$K3S_YAML" ]]; then
		info "would copy ${K3S_YAML} into ${KUBECONFIG_PATH}"
		return
	fi

	if [[ ! -r "$K3S_YAML" ]]; then
		# --write-kubeconfig-mode 644 should have handled this; repair if not.
		need_sudo
		[[ -e "$K3S_YAML" ]] || die "${K3S_YAML} does not exist; is k3s installed?"
		act "chmod 644 ${K3S_YAML} so it can be read without sudo"
		run $SUDO chmod 644 "$K3S_YAML"
	fi

	run mkdir -p "$(dirname "$KUBECONFIG_PATH")"

	if [[ -e "$KUBECONFIG_PATH" ]]; then
		die "${KUBECONFIG_PATH} exists but does not reach this cluster (perhaps left over from an earlier k3s). Fix it, or move it aside and re-run install to have it written from ${K3S_YAML}."
	fi

	act "write ${KUBECONFIG_PATH} from ${K3S_YAML}"
	run_sh "install -m 600 '$K3S_YAML' '$KUBECONFIG_PATH'"

	wait_for "the cluster to answer" 120 kubectl --kubeconfig "$KUBECONFIG_PATH" get --raw /readyz ||
		die "kubectl still cannot reach the cluster."
	wait_for "the node to become Ready" 180 \
		bash -c 'kubectl get nodes --no-headers 2>/dev/null | grep -qw Ready' ||
		warn "node is not Ready yet; continuing anyway."
}

ensure_helm() {
	head1 "helm"
	if have helm; then
		skip "helm present ($(command -v helm), $(helm version --short 2>/dev/null || echo 'version unknown'))"
		return
	fi
	local ver tmp
	ver=$(latest_github_tag helm/helm "$HELM_FALLBACK_VERSION")
	act "install helm ${ver} to ${BIN_DIR}"
	tmp=$(mktemp -d)
	run_sh "curl -fsSL 'https://get.helm.sh/helm-${ver}-linux-$(arch).tar.gz' | tar -xz -C '$tmp' \
		&& install -m 755 '$tmp/linux-$(arch)/helm' '${BIN_DIR}/helm'"
	rm -rf "$tmp"
	hash -r 2>/dev/null || true
}

ensure_zot() {
	head1 "Zot registry"

	local values_file="${WORK_DIR}/zot-values.yaml"
	zot_values > "$values_file"

	if ! helm repo list 2>/dev/null | awk '{print $2}' | grep -qx "https://zotregistry.dev/helm-charts"; then
		act "add the project-zot helm repo"
		run helm repo add project-zot https://zotregistry.dev/helm-charts --force-update
	else
		skip "project-zot helm repo already configured"
	fi
	run_sh "helm repo update project-zot >/dev/null"

	# Always upgrade: with unchanged values this is a no-op for the running pods,
	# and it applies any values changed by a newer gobag.sh.
	act "helm upgrade --install ${GOBAG_RELEASE} -n ${GOBAG_NAMESPACE}"
	run helm upgrade --install "$GOBAG_RELEASE" project-zot/zot \
		--namespace "$GOBAG_NAMESPACE" --create-namespace \
		--values "$values_file" --wait --timeout 5m

	# Kind-agnostic readiness wait: persistence:true makes this a StatefulSet.
	wait_for "a ready zot pod" 180 bash -c \
		"kubectl -n '$GOBAG_NAMESPACE' wait --for=condition=Ready pod \
			-l app.kubernetes.io/name=zot --timeout=10s" ||
		warn "no ready zot pod yet; check 'kubectl -n ${GOBAG_NAMESPACE} get pods'."

	if (( DRY_RUN )); then
		info "would verify the registry answers on its ClusterIP"
	elif wait_for "the registry API" 60 registry_reachable; then
		skip "registry answering on $(registry_endpoint)/v2/"
	else
		warn "registry is not answering on $(registry_endpoint || echo '<no ClusterIP>') yet."
	fi
}

# Teach the node's containerd to pull our registry name over plain HTTP from
# the zot Service's ClusterIP. Without this, containerd defaults to HTTPS and pulls fail with
# "http: server gave HTTP response to HTTPS client".
ensure_registries_yaml() {
	head1 "containerd registry mirror"

	if ! have k3s; then
		skip "not a k3s cluster; skipping ${REGISTRIES_YAML}"
		warn "you must configure your cluster's container runtime to pull ${REGISTRY} over plain HTTP yourself."
		return
	fi

	local endpoint
	if ! endpoint=$(registry_endpoint); then
		if (( DRY_RUN )); then
			info "would point the mirror for ${REGISTRY} at the zot Service's ClusterIP"
			info "(this step needs sudo)"
			return
		fi
		die "the zot Service has no ClusterIP yet; cannot write the containerd mirror."
	fi

	# Read the current file with as little privilege as possible.
	local current="" need_root=0
	if [[ -e "$REGISTRIES_YAML" ]]; then
		if [[ -r "$REGISTRIES_YAML" ]]; then
			current=$(cat "$REGISTRIES_YAML")
		else
			need_root=1
		fi
	fi
	if (( need_root )); then
		if (( DRY_RUN )); then
			info "would read ${REGISTRIES_YAML} with sudo and point ${REGISTRY} at ${endpoint}"
			return
		fi
		need_sudo
		current=$($SUDO cat "$REGISTRIES_YAML" 2>/dev/null || true)
	fi

	if [[ -n "$current" ]] && printf '%s' "$current" | grep -qF "\"${endpoint}\"" &&
		printf '%s' "$current" | grep -qF "\"${REGISTRY}\""; then
		skip "${REGISTRIES_YAML} already mirrors ${REGISTRY} to ${endpoint}"
		return
	fi

	local tmp
	tmp=$(mktemp)
	if [[ -z "$current" ]]; then
		act "create ${REGISTRIES_YAML} mirroring ${REGISTRY} to ${endpoint}"
		{ printf '%s\n' "$GOBAG_MARKER"; registries_yaml_stanza "$endpoint"; } > "$tmp"
	elif printf '%s' "$current" | head -1 | grep -qF "$GOBAG_MARKER"; then
		# gobag wrote this file, so it is ours to rewrite (e.g. a changed ClusterIP).
		act "update ${REGISTRIES_YAML}: point ${REGISTRY} at ${endpoint}"
		{ printf '%s\n' "$GOBAG_MARKER"; registries_yaml_stanza "$endpoint"; } > "$tmp"
	elif printf '%s' "$current" | grep -qF "\"${REGISTRY}\""; then
		# Someone else's file already names our registry, with a different
		# endpoint. Rewriting it could clobber a deliberate choice.
		rm -f "$tmp"
		die "$(cat <<-EOF
		${REGISTRIES_YAML} already has an entry for ${REGISTRY}, but pointing somewhere
		other than ${endpoint}, and gobag did not write that file. Fix it by hand so the
		endpoint reads:

		      - "${endpoint}"

		then restart k3s ('sudo systemctl restart k3s').
		EOF
		)"
	elif printf '%s' "$current" | grep -qE '^mirrors:[[:space:]]*$'; then
		# Insert our mapping as the first entry under the existing mirrors: key.
		act "add a mirror for ${REGISTRY} to the existing ${REGISTRIES_YAML}"
		printf '%s\n' "$current" | awk -v reg="$REGISTRY" -v ep="$endpoint" '
			{ print }
			!inserted && /^mirrors:[[:space:]]*$/ {
				printf "  \"%s\":\n    endpoint:\n      - \"%s\"\n", reg, ep
				inserted = 1
			}
		' > "$tmp"
	elif printf '%s' "$current" | grep -qE '^mirrors:'; then
		# mirrors: exists but in flow style (e.g. "mirrors: {}") - do not guess.
		rm -f "$tmp"
		die "$(cat <<-EOF
		${REGISTRIES_YAML} already has a 'mirrors:' key that gobag cannot safely edit
		(it is not a plain block mapping). Add this stanza by hand, then restart k3s
		('sudo systemctl restart k3s') and re-run:

		$(registries_yaml_stanza "$endpoint" | sed 's/^/  /')
		EOF
		)"
	else
		act "append a mirrors block for ${REGISTRY} to ${REGISTRIES_YAML}"
		{ printf '%s\n' "$current"; registries_yaml_stanza "$endpoint"; } > "$tmp"
	fi

	need_sudo

	if [[ -n "$current" ]]; then
		local backup
		backup="${REGISTRIES_YAML}.gobag-$(date +%Y%m%d%H%M%S).bak"
		info "existing file backed up to ${backup}"
		run $SUDO cp -p "$REGISTRIES_YAML" "$backup"
	fi

	if (( DRY_RUN )); then
		info "would write ${REGISTRIES_YAML}:"
		sed 's/^/           /' "$tmp"
	else
		$SUDO install -m 600 -o root -g root "$tmp" "$REGISTRIES_YAML"
	fi
	rm -f "$tmp"

	act "restart k3s to pick up the registry mirror"
	run $SUDO systemctl restart k3s
	wait_for "k3s to come back" 180 kubectl get --raw /readyz ||
		warn "k3s is slow to return after the restart; check 'systemctl status k3s'."
	wait_for "the registry after restart" 120 registry_reachable ||
		warn "registry not reachable after the k3s restart."
}

# The uninstall-time counterpart to ensure_registries_yaml: surgically drop
# just the mapping gobag added for $REGISTRY (its key line plus everything
# indented under it), leaving any other content in the file untouched, then
# restart k3s so the removal actually takes effect. Used by 'uninstall' so no
# stale mirror is ever left for the user to clean up by hand.
remove_registries_yaml_entry() {
	if [[ ! -e "$REGISTRIES_YAML" ]]; then
		skip "no ${REGISTRIES_YAML} to clean up"
		return
	fi

	local current=""
	if [[ -r "$REGISTRIES_YAML" ]]; then
		current=$(cat "$REGISTRIES_YAML")
	else
		if (( DRY_RUN )); then
			info "would read ${REGISTRIES_YAML} with sudo and remove the ${REGISTRY} mirror"
			return
		fi
		need_sudo
		current=$($SUDO cat "$REGISTRIES_YAML" 2>/dev/null || true)
	fi

	if ! printf '%s' "$current" | grep -qF "\"${REGISTRY}\""; then
		skip "${REGISTRIES_YAML} does not mirror ${REGISTRY}"
		return
	fi

	if (( DRY_RUN )); then
		info "would remove the ${REGISTRY} mirror from ${REGISTRIES_YAML}"
		return
	fi

	local updated
	updated=$(printf '%s\n' "$current" | awk -v want="  \"${REGISTRY}\":" '
		function indent(s) { match(s, /^[ \t]*/); return RLENGTH }
		BEGIN { skipping = 0; base = 0 }
		{
			if (skipping) {
				if (indent($0) > base) next
				skipping = 0
			}
			if ($0 == want) { skipping = 1; base = indent($0); next }
			print
		}
	')

	need_sudo
	local backup
	backup="${REGISTRIES_YAML}.gobag-$(date +%Y%m%d%H%M%S).bak"
	run $SUDO cp -p "$REGISTRIES_YAML" "$backup"
	info "existing file backed up to ${backup}"

	# If nothing meaningful is left once our mirror is gone - gobag wrote the
	# whole file originally - remove it outright instead of leaving an empty
	# husk behind.
	local remaining
	remaining=$(printf '%s\n' "$updated" |
		grep -v -e '^[[:space:]]*$' | grep -vxF "$GOBAG_MARKER" | grep -vE '^mirrors:[[:space:]]*$' || true)

	if [[ -z "$remaining" ]]; then
		act "remove ${REGISTRIES_YAML} (nothing left in it once our mirror is gone)"
		run $SUDO rm -f "$REGISTRIES_YAML"
	else
		act "remove the ${REGISTRY} mirror from ${REGISTRIES_YAML}"
		local tmp
		tmp=$(mktemp)
		printf '%s\n' "$updated" > "$tmp"
		run $SUDO install -m 600 -o root -g root "$tmp" "$REGISTRIES_YAML"
		rm -f "$tmp"
	fi

	act "restart k3s to drop the registry mirror"
	run $SUDO systemctl restart k3s
	wait_for "k3s to come back" 180 kubectl get --raw /readyz ||
		warn "k3s is slow to return after the restart; check 'systemctl status k3s'."
}

# Host-side convenience only: lets you curl/inspect the registry by the same
# name the cluster uses. Builds and pulls do not depend on this.
ensure_hosts_entry() {
	head1 "/etc/hosts entry"

	local ip
	if ! ip=$(registry_cluster_ip) || [[ -z "$ip" ]]; then
		if (( DRY_RUN )); then
			info "would map ${REGISTRY_HOST} to the zot Service's ClusterIP"
			return
		fi
		warn "no ClusterIP for the zot Service; skipping the /etc/hosts entry."
		return
	fi

	if grep -qE "^${ip}[[:space:]]+${REGISTRY_HOST}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
		skip "/etc/hosts already resolves ${REGISTRY_HOST} to ${ip}"
		return
	fi

	need_sudo
	if grep -qE "^[^#]*[[:space:]]${REGISTRY_HOST}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
		act "update the stale ${REGISTRY_HOST} entry in /etc/hosts to ${ip}"
		run_sh "$SUDO sed -i.gobag-bak -E '/[[:space:]]${REGISTRY_HOST}([[:space:]]|\$)/d' /etc/hosts"
	else
		act "map ${REGISTRY_HOST} to ${ip} in /etc/hosts"
	fi
	run_sh "printf '%s\t%s\t# gobag\n' '$ip' '$REGISTRY_HOST' | $SUDO tee -a /etc/hosts >/dev/null"
}

# devspace's in-cluster BuildKit path needs the buildx CLI (not a Docker daemon).
ensure_buildx() {
	head1 "buildx CLI"

	if have docker && docker buildx version >/dev/null 2>&1; then
		BUILDX=(docker buildx)
		skip "docker buildx available ($(docker buildx version 2>/dev/null | head -1))"
		return
	fi
	if have buildx; then
		BUILDX=(buildx)
		skip "standalone buildx available ($(command -v buildx))"
		return
	fi

	local ver dest
	ver=$(latest_github_tag docker/buildx "$BUILDX_FALLBACK_VERSION")
	dest="${BIN_DIR}/buildx"
	act "install standalone buildx ${ver} to ${dest}"
	run curl -fsSL -o "$dest" \
		"https://github.com/docker/buildx/releases/download/${ver}/buildx-${ver}.linux-$(arch)"
	run chmod +x "$dest"

	# Also register it as a docker CLI plugin when the docker CLI exists, so
	# plain "docker buildx" works too.
	if have docker; then
		act "register buildx as a docker CLI plugin"
		run mkdir -p "$HOME/.docker/cli-plugins"
		run ln -sf "$dest" "$HOME/.docker/cli-plugins/docker-buildx"
	fi

	hash -r 2>/dev/null || true
	BUILDX=(buildx)
}

# Create the builder devspace would otherwise create on its first in-cluster
# build, under the same name, so the ~35s wait for its pod to become ready is
# paid here rather than by the first build.
ensure_builder() {
	head1 "in-cluster BuildKit builder"
	if "${BUILDX[@]}" inspect "$GOBAG_BUILDER" >/dev/null 2>&1; then
		skip "buildx builder '${GOBAG_BUILDER}' already exists"
		return
	fi
	act "create buildx builder '${GOBAG_BUILDER}' in namespace ${GOBAG_NAMESPACE}"
	run "${BUILDX[@]}" create --driver kubernetes --name "$GOBAG_BUILDER" \
		--driver-opt namespace="$GOBAG_NAMESPACE" --bootstrap
}

ensure_devspace() {
	head1 "devspace"
	if have devspace; then
		skip "devspace present ($(command -v devspace), $(devspace --version 2>/dev/null | tail -1))"
		return
	fi
	act "install devspace to ${BIN_DIR}"
	run curl -fsSL -o "${BIN_DIR}/devspace" \
		"https://github.com/devspace-sh/devspace/releases/latest/download/devspace-linux-$(arch)"
	run chmod +x "${BIN_DIR}/devspace"
	hash -r 2>/dev/null || true
}

summary() {
	local devspace_command=""
	[[ "${BUILDX[*]}" == "buildx" ]] && devspace_command=$'\n        command: ["buildx"]'

	cat <<-EOF

		${C_BOLD}${C_GREEN}gobag is ready.${C_RESET}

		  Registry:  ${C_BOLD}${REGISTRY}${C_RESET}

		Use it in devspace.yaml:

		  images:
		    app:
		      image: ${REGISTRY}/app
		      buildKit:${devspace_command}
		        args: ["--output", "type=image,push=true,registry.insecure=true"]
		        inCluster:
		          namespace: ${GOBAG_NAMESPACE}
		  localRegistry:
		    enabled: false

		See examples/devspace.yaml for a complete file.

		Test the whole build -> push -> pull chain with:
		  ${C_BOLD}./gobag-test.sh${C_RESET}
	EOF
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

cmd_install() {
	preflight
	ensure_cluster
	ensure_kubeconfig
	ensure_helm
	ensure_zot
	ensure_registries_yaml
	ensure_hosts_entry
	ensure_buildx
	ensure_builder
	ensure_devspace
	if (( DRY_RUN )); then
		say ""
		say "Dry run complete; nothing was changed."
	else
		summary
	fi
}

status_line() {
	printf '  %-22s %s\n' "$1" "$2"
}

cmd_check() {
	head1 "gobag status (read-only)"

	local ok="${C_GREEN}ok${C_RESET}" no="${C_YELLOW}missing${C_RESET}"

	status_line "platform" "$(uname -s) $(uname -m)$(is_wsl && printf ' (WSL)')"
	status_line "init" "$(ps -p 1 -o comm= 2>/dev/null)"
	status_line "cgroup" "$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo none)"

	for tool in kubectl helm devspace; do
		if have "$tool"; then
			status_line "$tool" "$ok ($(command -v "$tool"))"
		else
			status_line "$tool" "$no"
		fi
	done

	if have docker && docker buildx version >/dev/null 2>&1; then
		status_line "buildx" "$ok (docker buildx)"
	elif have buildx; then
		status_line "buildx" "$ok (standalone)"
	else
		status_line "buildx" "$no"
	fi

	if cluster_reachable; then
		local nodes
		nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c . || echo 0)
		status_line "cluster" "$ok (${nodes} node(s), $(kubectl config current-context 2>/dev/null))"
	else
		status_line "cluster" "$no (kubectl cannot reach a cluster)"
	fi

	if helm status "$GOBAG_RELEASE" -n "$GOBAG_NAMESPACE" >/dev/null 2>&1; then
		status_line "zot release" "$ok (${GOBAG_NAMESPACE}/${GOBAG_RELEASE})"
	else
		status_line "zot release" "$no"
	fi

	local endpoint=""
	endpoint=$(registry_endpoint) || true
	if registry_reachable; then
		status_line "registry" "$ok (${endpoint}/v2/)"
	elif [[ -n "$endpoint" ]]; then
		status_line "registry" "$no (${endpoint} not answering)"
	else
		status_line "registry" "$no (no zot Service, so no ClusterIP)"
	fi

	# A stale mirror endpoint is the one failure that would otherwise show up
	# only as a confusing ImagePullBackOff, so call it out explicitly.
	if [[ -r "$REGISTRIES_YAML" ]]; then
		if [[ -n "$endpoint" ]] && grep -qF "\"${endpoint}\"" "$REGISTRIES_YAML" 2>/dev/null; then
			status_line "containerd mirror" "$ok (-> ${endpoint})"
		elif grep -qF "\"${REGISTRY}\"" "$REGISTRIES_YAML" 2>/dev/null; then
			status_line "containerd mirror" "${C_YELLOW}stale${C_RESET} (points elsewhere; expected ${endpoint:-?}) - re-run install"
		else
			status_line "containerd mirror" "$no (no entry for ${REGISTRY})"
		fi
	else
		status_line "containerd mirror" "${C_DIM}unknown (needs sudo to read)${C_RESET}"
	fi

	if [[ -n "$endpoint" ]] && grep -qE "^$(registry_cluster_ip)[[:space:]]+${REGISTRY_HOST}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
		status_line "/etc/hosts" "$ok"
	elif grep -qE "^[^#]*[[:space:]]${REGISTRY_HOST}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
		status_line "/etc/hosts" "${C_YELLOW}stale${C_RESET} (wrong address; host-side convenience only)"
	else
		status_line "/etc/hosts" "$no (host-side convenience only)"
	fi

	status_line "registry URL" "$REGISTRY"
	say ""
}

# True if $1 has the shape of k3s's own kubeconfig: one cluster, context and
# user, all named "default", for the local k3s API server.
is_k3s_kubeconfig() {
	[[ -r "$1" ]] || return 1
	awk '
		/^[[:space:]]*server:/ { servers++; if ($2 != "https://127.0.0.1:6443") bad = 1 }
		/^[[:space:]]*(- )?name:/ { if ($NF != "default") bad = 1 }
		END { exit !(servers == 1 && !bad) }
	' "$1"
}

cmd_uninstall() {
	head1 "Uninstalling gobag components"

	local k3s_uninstall="/usr/local/bin/k3s-uninstall.sh" remove_k3s=0
	if [[ -x "$k3s_uninstall" ]]; then
		if confirm "Remove k3s too (deletes the whole cluster and everything in it)?"; then
			remove_k3s=1
		else
			skip "keeping k3s"
		fi
	fi

	local bx=(docker buildx)
	have docker && docker buildx version >/dev/null 2>&1 || bx=(buildx)
	if have "${bx[0]}" && "${bx[@]}" inspect "$GOBAG_BUILDER" >/dev/null 2>&1; then
		act "remove buildx builder ${GOBAG_BUILDER}"
		run "${bx[@]}" rm "$GOBAG_BUILDER"
	else
		skip "no buildx builder to remove"
	fi

	if (( remove_k3s )); then
		:
	elif ! cluster_reachable; then
		skip "no reachable cluster; nothing to remove from it"
	else
		if have helm && helm status "$GOBAG_RELEASE" -n "$GOBAG_NAMESPACE" >/dev/null 2>&1; then
			act "helm uninstall ${GOBAG_RELEASE}"
			run helm uninstall "$GOBAG_RELEASE" -n "$GOBAG_NAMESPACE" --wait --timeout 3m
		else
			skip "no zot release to remove"
		fi

		if kubectl get ns "$GOBAG_NAMESPACE" >/dev/null 2>&1; then
			if confirm "Delete namespace ${GOBAG_NAMESPACE} (destroys the registry's stored images)?"; then
				act "delete namespace ${GOBAG_NAMESPACE}"
				run kubectl delete ns "$GOBAG_NAMESPACE" --timeout=3m
			else
				skip "keeping namespace ${GOBAG_NAMESPACE}"
			fi
		fi
	fi

	if have helm && helm repo list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx project-zot; then
		act "remove the project-zot helm repo"
		run helm repo remove project-zot
	else
		skip "no project-zot helm repo to remove"
	fi

	if grep -qE "^[^#]*[[:space:]]${REGISTRY_HOST}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
		need_sudo
		act "remove the ${REGISTRY_HOST} entry from /etc/hosts"
		run_sh "$SUDO sed -i.gobag-bak '/[[:space:]]${REGISTRY_HOST}[[:space:]]*#\\? *gobag\$/d' /etc/hosts"
	fi

	# install writes ~/.kube/config as a plain copy of k3s's kubeconfig. Once k3s
	# is gone it is useless, and it would break the next install with the old
	# cluster's CA, so remove it.
	if (( remove_k3s )) || ! have k3s; then
		if is_k3s_kubeconfig "$KUBECONFIG_PATH"; then
			act "remove ${KUBECONFIG_PATH} (the k3s kubeconfig install wrote)"
			run rm -f "$KUBECONFIG_PATH"
		elif [[ -e "$KUBECONFIG_PATH" ]]; then
			skip "${KUBECONFIG_PATH} has other clusters in it; leaving it"
		fi
	fi

	if (( remove_k3s )); then
		need_sudo
		act "remove k3s"
		run $SUDO "$k3s_uninstall"
	elif have k3s; then
		remove_registries_yaml_entry
	fi

	local tool
	for tool in helm buildx devspace kubectl; do
		if [[ -e "${BIN_DIR}/${tool}" ]]; then
			act "remove ${BIN_DIR}/${tool}"
			run rm -f "${BIN_DIR}/${tool}"
		fi
	done
	local plugin="$HOME/.docker/cli-plugins/docker-buildx"
	if [[ -L "$plugin" && "$(readlink "$plugin")" == "${BIN_DIR}/buildx" ]]; then
		act "remove the docker buildx plugin link ${plugin}"
		run rm -f "$plugin"
	fi

	say ""
	say "Done."
	is_wsl && say "/etc/wsl.conf and .wslconfig were left alone."
	return 0
}

usage() {
	cat <<-EOF
		${C_BOLD}gobag.sh${C_RESET} - one-shot setup of a local Kubernetes dev environment

		${C_BOLD}Usage:${C_RESET}
		  ./gobag.sh [command] [options]

		${C_BOLD}Commands:${C_RESET}
		  install      Set everything up (default). Idempotent; safe to re-run.
		  check        Print the status of every component. Read-only.
		  uninstall    Remove everything install set up, including k3s (asks first).

		${C_BOLD}Options:${C_RESET}
		  -n, --dry-run        Show what would change without changing it.
		  -y, --yes            Assume yes for confirmation prompts.
		  -q, --quiet          Only print warnings and errors.
		  -h, --help           Show this help.
	EOF
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main() {
	local cmd=""
	while (( $# )); do
		case "$1" in
			install | check | uninstall) cmd="$1" ;;
			-n | --dry-run) DRY_RUN=1 ;;
			-y | --yes) ASSUME_YES=1 ;;
			-q | --quiet) QUIET=1 ;;
			-h | --help) usage; return 0 ;;
			*) usage >&2; die "unknown argument: $1" ;;
		esac
		shift
	done

	WORK_DIR=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$WORK_DIR'" EXIT

	case "${cmd:-install}" in
		install) cmd_install ;;
		check) cmd_check ;;
		uninstall) cmd_uninstall ;;
	esac
}

main "$@"
