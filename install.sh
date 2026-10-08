#!/bin/sh
# Set up rclone for SteadyLink on macOS and Linux.
#
#   curl -fsSL https://steadylink.io/install/rclone.sh | sh
#
# Pass an app key to skip the prompts:
#
#   curl -fsSL https://steadylink.io/install/rclone.sh | \
#     STEADYLINK_ACCESS_KEY_ID=SL... STEADYLINK_SECRET_ACCESS_KEY=... sh
#
# Options go after `sh -s --`, for example `... | sh -s -- --uninstall`.
# Source and documentation: https://github.com/SteadyLink-io/rclone-setup
# steadylink.io serves a copy of this file. Make changes in that repository.

set -eu

REPO_URL="https://github.com/SteadyLink-io/rclone-setup"
MIN_MAJOR=1
MIN_MINOR=65

ENDPOINT="${STEADYLINK_ENDPOINT:-https://api.steadylink.io/s3}"
REMOTE="${STEADYLINK_REMOTE:-steadylink}"
NONINTERACTIVE="${STEADYLINK_NONINTERACTIVE:-0}"
KEY_ID="${STEADYLINK_ACCESS_KEY_ID:-}"
SECRET="${STEADYLINK_SECRET_ACCESS_KEY:-}"
ACTION=setup
[ "${STEADYLINK_UNINSTALL:-0}" = 1 ] && ACTION=uninstall

usage() {
	cat <<EOF
Set up rclone for SteadyLink.

Usage: install.sh [--uninstall] [--non-interactive] [--remote NAME]

  --uninstall        Remove the mount and backup jobs this script created.
                     Asks before removing the rclone remote or rclone itself.
  --non-interactive  Configure the remote only. Never prompt. Same as
                     STEADYLINK_NONINTERACTIVE=1.
  --remote NAME      Name of the rclone remote (default: steadylink).
  -h, --help         Show this help.

Environment:
  STEADYLINK_ACCESS_KEY_ID       App key ID (starts with SL)
  STEADYLINK_SECRET_ACCESS_KEY   App key secret
  STEADYLINK_ENDPOINT            Default: https://api.steadylink.io/s3
  STEADYLINK_REMOTE              Default: steadylink
  STEADYLINK_NONINTERACTIVE=1    Same as --non-interactive

Docs: $REPO_URL
EOF
}

# ---------------------------------------------------------------------------
# Output

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	BOLD=$(printf '\033[1m')
	DIM=$(printf '\033[2m')
	RED=$(printf '\033[31m')
	GREEN=$(printf '\033[32m')
	YELLOW=$(printf '\033[33m')
	RESET=$(printf '\033[0m')
else
	BOLD='' DIM='' RED='' GREEN='' YELLOW='' RESET=''
fi

say() { printf '%s\n' "$*"; }
step() { printf '\n%s%s%s\n' "$BOLD" "$*" "$RESET"; }
ok() { printf '%sok%s %s\n' "$GREEN" "$RESET" "$*"; }
note() { printf '%s%s%s\n' "$DIM" "$*" "$RESET"; }
warn() { printf '%swarning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die() {
	printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# Arguments

while [ $# -gt 0 ]; do
	case "$1" in
	--uninstall) ACTION=uninstall ;;
	--non-interactive | --noninteractive) NONINTERACTIVE=1 ;;
	--remote)
		[ $# -ge 2 ] || die "--remote needs a name"
		REMOTE=$2
		shift
		;;
	--remote=*) REMOTE=${1#--remote=} ;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "unknown option: $1 (try --help)" ;;
	esac
	shift
done

case "$REMOTE" in
'' | *[!A-Za-z0-9_-]*) die "remote name may only contain letters, digits, - and _: '$REMOTE'" ;;
esac
[ "$NONINTERACTIVE" = 1 ] || NONINTERACTIVE=0

# ---------------------------------------------------------------------------
# Prompts. This script usually arrives on stdin through a pipe, so questions
# are asked on /dev/tty. Without a terminal we behave as --non-interactive.

TTY=
if [ "$NONINTERACTIVE" = 0 ] && (: </dev/tty) 2>/dev/null; then
	TTY=/dev/tty
fi

TMP=
ECHO_OFF=0
cleanup() {
	if [ "$ECHO_OFF" = 1 ]; then stty echo <"$TTY" 2>/dev/null || true; fi
	if [ -n "$TMP" ]; then rm -rf "$TMP"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

interactive() { [ -n "$TTY" ]; }

# ask "Question" "default"  -> sets REPLY
ask() {
	if [ -n "$2" ]; then
		printf '%s [%s]: ' "$1" "$2" >"$TTY"
	else
		printf '%s: ' "$1" >"$TTY"
	fi
	REPLY=
	IFS= read -r REPLY <"$TTY" || true
	[ -n "$REPLY" ] || REPLY=$2
}

# ask_secret "Prompt"  -> sets REPLY without echoing what is typed
ask_secret() {
	printf '%s: ' "$1" >"$TTY"
	ECHO_OFF=1
	stty -echo <"$TTY" 2>/dev/null || true
	REPLY=
	IFS= read -r REPLY <"$TTY" || true
	stty echo <"$TTY" 2>/dev/null || true
	ECHO_OFF=0
	printf '\n' >"$TTY"
}

# confirm "Question" y|n  -> returns 0 for yes. Without a terminal, uses the default.
confirm() {
	if ! interactive; then [ "$2" = y ]; return; fi
	if [ "$2" = y ]; then hint="Y/n"; else hint="y/N"; fi
	while :; do
		printf '%s [%s] ' "$1" "$hint" >"$TTY"
		answer=
		IFS= read -r answer <"$TTY" || true
		[ -n "$answer" ] || answer=$2
		case "$answer" in
		[Yy] | [Yy][Ee][Ss]) return 0 ;;
		[Nn] | [Nn][Oo]) return 1 ;;
		esac
	done
}

# ---------------------------------------------------------------------------
# Helpers

OS=$(uname -s)
case "$OS" in
Linux | Darwin) ;;
*) die "this script supports macOS and Linux. On Windows use install.ps1: $REPO_URL" ;;
esac

have() { command -v "$1" >/dev/null 2>&1; }

as_root() {
	if [ "$(id -u)" -eq 0 ]; then
		"$@"
	elif have sudo; then
		sudo "$@"
	else
		return 127
	fi
}

can_be_root() { [ "$(id -u)" -eq 0 ] || have sudo; }

make_tmp() {
	if [ -z "$TMP" ]; then
		TMP=$(mktemp -d 2>/dev/null || mktemp -d -t steadylink)
	fi
}

download() { curl -fsSL --proto '=https' --tlsv1.2 -o "$2" "$1"; }

sha256_of() {
	if have sha256sum; then
		sha256sum "$1" | awk '{print $1}'
	elif have shasum; then
		shasum -a 256 "$1" | awk '{print $1}'
	else
		return 1
	fi
}

# Print the input with the secret replaced, so error output can be shown safely.
redact() {
	SL_REDACT="$SECRET" awk 'BEGIN { s = ENVIRON["SL_REDACT"] }
		{ if (s != "") { while ((i = index($0, s)) > 0) $0 = substr($0, 1, i - 1) "****" substr($0, i + length(s)) } print }'
}

# Quote a value for a systemd ExecStart= line.
sd_quote() {
	printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/%/%%/g' -e 's/\$/$$/g')"
}

# Escape free text (Description=) for a systemd unit.
sd_text() { printf '%s' "$1" | sed -e 's/%/%%/g'; }

# Escape a value for a plist <string>.
xml_escape() {
	printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Quote a value for a POSIX shell command line.
sh_quote() {
	printf "'%s'" "$(printf '%s' "$1" | sed -e "s/'/'\\\\''/g")"
}

slugify() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed -e 's/--*/-/g' -e 's/^-//' -e 's/-$//'
}

# ---------------------------------------------------------------------------
# rclone

RCLONE=

find_rclone() {
	RCLONE=
	if have rclone; then
		RCLONE=$(command -v rclone)
		return 0
	fi
	for candidate in /usr/local/bin/rclone /usr/bin/rclone /opt/homebrew/bin/rclone "$HOME/.local/bin/rclone"; do
		if [ -x "$candidate" ]; then
			RCLONE=$candidate
			return 0
		fi
	done
	return 1
}

rclone_version() {
	"$RCLONE" version 2>/dev/null | sed -n '1s/^rclone v\{0,1\}\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p'
}

version_ok() {
	major=${1%%.*}
	minor=${1#*.}
	minor=${minor%%.*}
	[ "$major" -gt "$MIN_MAJOR" ] || { [ "$major" -eq "$MIN_MAJOR" ] && [ "$minor" -ge "$MIN_MINOR" ]; }
}

from_homebrew() {
	have brew || return 1
	prefix=$(brew --prefix 2>/dev/null) || return 1
	case "$(cd "$(dirname "$RCLONE")" && pwd -P)/" in
	"$prefix"/* | /opt/homebrew/* | /usr/local/Cellar/*) return 0 ;;
	esac
	[ -L "$RCLONE" ] && case "$(readlink "$RCLONE")" in *Cellar*) return 0 ;; esac
	return 1
}

# rclone's official installer (https://rclone.org/install.sh) puts the binary
# in /usr/bin or /usr/local/bin and needs root.
install_official() {
	if ! have unzip && ! have 7z && ! have busybox; then
		die "the rclone installer needs unzip. Install it (for example 'sudo apt install unzip') and run this again."
	fi
	make_tmp
	say "Downloading rclone's official installer from https://rclone.org/install.sh"
	download https://rclone.org/install.sh "$TMP/rclone-install.sh"
	if [ "$(id -u)" -ne 0 ]; then say "It installs into a system directory, so sudo may ask for your password."; fi
	status=0
	as_root bash "$TMP/rclone-install.sh" </dev/null || status=$?
	# Exit code 3 means the latest version is already installed.
	[ "$status" -eq 0 ] || [ "$status" -eq 3 ] || die "rclone's installer failed (exit $status)."
}

# Without root or sudo: download the release zip, check it against the
# published SHA256SUMS and put the binary in ~/.local/bin.
install_user_local() {
	have unzip || die "unzip is needed to install rclone without root. Install unzip, or install rclone yourself: https://rclone.org/downloads/"
	case "$(uname -m)" in
	x86_64 | amd64) arch=amd64 ;;
	aarch64 | arm64) arch=arm64 ;;
	armv7*) arch=arm-v7 ;;
	armv6* | armv5*) arch=arm ;;
	i386 | i686) arch=386 ;;
	*) die "no rclone build for $(uname -m). See https://rclone.org/downloads/" ;;
	esac
	if [ "$OS" = Darwin ]; then os=osx; else os=linux; fi
	make_tmp
	version=$(curl -fsSL https://downloads.rclone.org/version.txt | awk '{print $2}')
	case "$version" in v[0-9]*) ;; *) die "could not read the current rclone version from downloads.rclone.org" ;; esac
	zip="rclone-$version-$os-$arch.zip"
	say "Downloading $zip"
	download "https://downloads.rclone.org/$version/$zip" "$TMP/$zip"
	download "https://downloads.rclone.org/$version/SHA256SUMS" "$TMP/SHA256SUMS"
	expected=$(awk -v f="$zip" '$2 == f { print $1 }' "$TMP/SHA256SUMS")
	actual=$(sha256_of "$TMP/$zip") || die "sha256sum or shasum is needed to check the download"
	if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
		die "checksum mismatch for $zip; not installing it"
	fi
	ok "checksum matches SHA256SUMS"
	unzip -q "$TMP/$zip" -d "$TMP"
	mkdir -p "$HOME/.local/bin"
	cp "$TMP/rclone-$version-$os-$arch/rclone" "$HOME/.local/bin/rclone.new"
	chmod 755 "$HOME/.local/bin/rclone.new"
	mv "$HOME/.local/bin/rclone.new" "$HOME/.local/bin/rclone"
	case ":$PATH:" in
	*":$HOME/.local/bin:"*) ;;
	*) warn "$HOME/.local/bin is not on your PATH. Add it in your shell profile to run rclone by name." ;;
	esac
}

ensure_rclone() {
	step "Checking rclone"
	current=
	if find_rclone; then
		current=$(rclone_version)
		if [ -n "$current" ] && version_ok "$current"; then
			ok "rclone $current at $RCLONE"
			return 0
		fi
		say "rclone ${current:-of unknown version} is installed at $RCLONE, but $MIN_MAJOR.$MIN_MINOR or newer is needed."
	else
		say "rclone is not installed."
	fi

	if interactive && ! confirm "Install the current rclone release?" y; then
		die "rclone $MIN_MAJOR.$MIN_MINOR or newer is required."
	fi

	if [ -n "$RCLONE" ] && from_homebrew; then
		brew upgrade rclone
	elif [ -z "$RCLONE" ] && [ "$OS" = Darwin ] && have brew; then
		brew install rclone
	elif can_be_root; then
		install_official
	else
		install_user_local
	fi

	hash -r 2>/dev/null || true
	find_rclone || die "rclone was installed but cannot be found on PATH. Open a new terminal and run this again."
	current=$(rclone_version)
	if [ -z "$current" ] || ! version_ok "$current"; then
		die "rclone at $RCLONE is still older than $MIN_MAJOR.$MIN_MINOR. Remove it and run this again."
	fi
	ok "rclone $current at $RCLONE"
}

CONFIG_FILE=

load_config() {
	CONFIG_FILE=$("$RCLONE" config file </dev/null | tail -n 1)
	if [ -f "$CONFIG_FILE" ] && head -n 1 "$CONFIG_FILE" | grep -q '^# Encrypted rclone configuration'; then
		if [ -z "${RCLONE_CONFIG_PASS:-}" ]; then
			interactive || die "your rclone config is encrypted. Set RCLONE_CONFIG_PASS and run this again."
			ask_secret "rclone config password"
			RCLONE_CONFIG_PASS=$REPLY
			export RCLONE_CONFIG_PASS
		fi
		"$RCLONE" listremotes </dev/null >/dev/null 2>&1 || die "could not open the rclone config. Check the password."
		CONFIG_ENCRYPTED=1
	else
		CONFIG_ENCRYPTED=0
	fi
}

remote_type() {
	"$RCLONE" listremotes --long </dev/null 2>/dev/null | awk -v r="$REMOTE:" '$1 == r { print $2 }'
}

# ---------------------------------------------------------------------------
# Remote

read_keys() {
	KEY_ID=$(printf '%s' "$KEY_ID" | tr -d '[:space:]')
	SECRET=$(printf '%s' "$SECRET" | tr -d '[:space:]')
	if [ -z "$KEY_ID" ] || [ -z "$SECRET" ]; then
		interactive || die "no app key. Set STEADYLINK_ACCESS_KEY_ID and STEADYLINK_SECRET_ACCESS_KEY, or run this in a terminal."
		say "You need a SteadyLink app key. The secret is shown only once, when the key is created."
	fi
	while [ -z "$KEY_ID" ]; do
		ask "Access key ID" ""
		KEY_ID=$(printf '%s' "$REPLY" | tr -d '[:space:]')
	done
	case "$KEY_ID" in
	SL*) ;;
	*) warn "SteadyLink access key IDs start with SL. '$KEY_ID' may not be a SteadyLink app key." ;;
	esac
	while [ -z "$SECRET" ]; do
		ask_secret "Secret access key (input hidden)"
		SECRET=$(printf '%s' "$REPLY" | tr -d '[:space:]')
	done
}

configure_remote() {
	step "Configuring the rclone remote '$REMOTE'"
	load_config
	existing=$(remote_type)
	verb=create
	if [ -n "$existing" ]; then
		if interactive; then
			confirm "A remote called '$REMOTE' already exists. Replace its settings with this key?" n ||
				die "left '$REMOTE' unchanged. Run again with STEADYLINK_REMOTE=another-name to add a second remote."
		else
			say "Updating the existing remote '$REMOTE'."
		fi
		if [ "$existing" = s3 ]; then verb=update; else verb=recreate; fi
	fi

	if [ "$verb" = recreate ]; then
		"$RCLONE" config delete "$REMOTE" </dev/null >/dev/null
		verb=create
	fi

	# rclone prints the whole remote, secret included, after create and update,
	# so the output is kept out of the terminal.
	if [ "$verb" = create ]; then
		set -- config create "$REMOTE" s3
	else
		set -- config update "$REMOTE"
	fi
	if ! out=$("$RCLONE" "$@" \
		provider=Other \
		env_auth=false \
		access_key_id="$KEY_ID" \
		secret_access_key="$SECRET" \
		endpoint="$ENDPOINT" \
		region=auto \
		force_path_style=true \
		--non-interactive </dev/null 2>&1); then
		printf '%s\n' "$out" | redact >&2
		die "rclone could not save the remote."
	fi
	ok "saved '$REMOTE' in $CONFIG_FILE"
	if [ "$CONFIG_ENCRYPTED" = 0 ]; then
		note "The secret is stored in that file, readable only by you. To encrypt the file, run: rclone config encryption set"
	fi
}

explain_error() {
	case "$1" in
	*SignatureDoesNotMatch*)
		say "SteadyLink recognised the access key ID, but the secret does not match it."
		say "Copy the secret again, without spaces or line breaks. If you no longer have it, create a new app key." ;;
	*InvalidAccessKeyId*)
		say "SteadyLink does not know this access key ID. It may be mistyped or the key may have been revoked."
		say "Check that it starts with SL, or create a new app key." ;;
	*RequestTimeTooSkewed*)
		say "Your computer's clock is too far off for the request to be accepted. Turn on automatic time sync and try again." ;;
	*QuotaExceeded*)
		say "The key works, but the workspace has used its storage allowance." ;;
	*SlowDown*)
		say "SteadyLink is rate limiting this key. Wait a minute and run the check again: rclone lsd $REMOTE:" ;;
	*AccessDenied*)
		say "The key was rejected. Usually it has been revoked, or its owner was removed from the workspace"
		say "or no longer has access. Create a new app key, or ask a workspace admin to check your role." ;;
	*"no such host"* | *"server misbehaving"* | *"dial tcp"* | *"connection refused"* | *timeout*)
		say "Could not reach $ENDPOINT. Check your internet connection, proxy or firewall." ;;
	*x509* | *certificate*)
		say "The TLS certificate for $ENDPOINT could not be verified. A proxy or antivirus that inspects HTTPS traffic"
		say "is the usual cause. Your clock may also be wrong." ;;
	*)
		say "rclone could not list buckets. Its last message is above." ;;
	esac
}

BUCKETS=

verify_remote() {
	step "Checking the connection"
	if out=$("$RCLONE" lsd "$REMOTE:" --retries 1 --low-level-retries 2 --contimeout 15s --timeout 60s </dev/null 2>&1); then
		BUCKETS=$(printf '%s\n' "$out" | awk 'NF >= 5 { print $NF }')
		if [ -n "$BUCKETS" ]; then
			ok "connected. Buckets this key can see:"
			printf '%s\n' "$BUCKETS" | sed 's/^/    /'
		else
			ok "connected. This key cannot see any buckets yet."
			note "Create one in the dashboard, or with: rclone mkdir $REMOTE:my-bucket"
		fi
		return 0
	fi
	printf '%s\n' "$out" | redact | grep -i 'error' | tail -n 3 | sed 's/^/    /' >&2 || true
	printf '\n' >&2
	explain_error "$out" >&2
	say "" >&2
	say "The remote was saved. Run this script again with the right key to replace it." >&2
	return 1
}

# ---------------------------------------------------------------------------
# Paths for services

if [ "$OS" = Darwin ]; then
	LOG_DIR="$HOME/Library/Logs/SteadyLink"
	AGENT_DIR="$HOME/Library/LaunchAgents"
else
	LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/steadylink"
	UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
fi

has_systemd_user() {
	have systemctl && systemctl --user show-environment >/dev/null 2>&1
}

encrypted_config_warning() {
	if [ "$CONFIG_ENCRYPTED" = 1 ]; then
		warn "your rclone config is encrypted, so this job cannot read it without a password."
		warn "Add --password-command to the job, or keep a separate unencrypted config for it."
	fi
}

# launchd: write ~/Library/LaunchAgents/<label>.plist and load it.
# Usage: write_launch_agent LABEL LOGFILE SCHEDULE_XML ARG...
write_launch_agent() {
	label=$1 logfile=$2 schedule=$3
	shift 3
	plist="$AGENT_DIR/$label.plist"
	mkdir -p "$AGENT_DIR" "$LOG_DIR"
	{
		printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
		printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
		printf '%s\n' '<plist version="1.0">' '<dict>'
		printf '  <key>Label</key><string>%s</string>\n' "$label"
		printf '  <key>ProgramArguments</key>\n  <array>\n'
		for arg in "$@"; do printf '    <string>%s</string>\n' "$(xml_escape "$arg")"; done
		printf '  </array>\n'
		printf '  <key>StandardOutPath</key><string>%s</string>\n' "$(xml_escape "$logfile")"
		printf '  <key>StandardErrorPath</key><string>%s</string>\n' "$(xml_escape "$logfile")"
		printf '%s\n' "$schedule"
		printf '%s\n' '</dict>' '</plist>'
	} >"$plist.tmp"
	mv "$plist.tmp" "$plist"
	launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
	launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || launchctl load -w "$plist"
}

remove_launch_agent() {
	launchctl bootout "gui/$(id -u)/$1" >/dev/null 2>&1 || launchctl unload "$AGENT_DIR/$1.plist" >/dev/null 2>&1 || true
	rm -f "$AGENT_DIR/$1.plist"
}

# ---------------------------------------------------------------------------
# Mount

offer_mount() {
	step "Mount SteadyLink as a folder"
	say "This shows your buckets as folders and mounts them each time you log in."
	confirm "Set up the mount?" n || return 0
	if [ "$OS" = Darwin ]; then setup_mount_macos; else setup_mount_linux; fi
}

pick_mount_dir() {
	ask "Mount at" "$HOME/SteadyLink"
	MOUNT_DIR=$REPLY
	case "$MOUNT_DIR" in "~"/*) MOUNT_DIR="$HOME/${MOUNT_DIR#\~/}" ;; esac
	case "$MOUNT_DIR" in /*) ;; *) MOUNT_DIR="$PWD/$MOUNT_DIR" ;; esac
	mkdir -p "$MOUNT_DIR"
	if [ -n "$(ls -A "$MOUNT_DIR" 2>/dev/null)" ] && ! mounted "$MOUNT_DIR"; then
		warn "$MOUNT_DIR is not empty. Pick an empty folder."
		return 1
	fi
}

mounted() { mount | grep -F " $1 " >/dev/null 2>&1; }

setup_mount_linux() {
	fusermount=$(command -v fusermount3 || command -v fusermount || true)
	if [ -z "$fusermount" ]; then
		warn "FUSE is not installed. Install the fuse3 package, then run this script again:"
		say "    Debian/Ubuntu: sudo apt install fuse3"
		say "    Fedora:        sudo dnf install fuse3"
		say "    Arch:          sudo pacman -S fuse3"
		return 0
	fi
	if ! has_systemd_user; then
		warn "no systemd user session here (common in WSL and containers), so the mount cannot start at login."
		say "Mount by hand with:"
		say "    rclone mount $REMOTE: ~/SteadyLink --vfs-cache-mode full --daemon"
		return 0
	fi
	pick_mount_dir || return 0
	encrypted_config_warning
	mkdir -p "$UNIT_DIR" "$LOG_DIR"
	unit="$UNIT_DIR/steadylink-mount.service"
	{
		printf '%s\n' "[Unit]"
		printf '%s\n' "Description=SteadyLink mount ($REMOTE: at $(sd_text "$MOUNT_DIR"))"
		printf '%s\n' "Documentation=$REPO_URL"
		printf '%s\n' "Wants=network-online.target" "After=network-online.target" ""
		printf '%s\n' "[Service]" "Type=notify"
		printf 'ExecStart=%s mount %s %s --config %s --vfs-cache-mode full --vfs-cache-max-age 24h --dir-cache-time 5m --log-file %s --log-level NOTICE\n' \
			"$(sd_quote "$RCLONE")" "$REMOTE:" "$(sd_quote "$MOUNT_DIR")" "$(sd_quote "$CONFIG_FILE")" "$(sd_quote "$LOG_DIR/mount.log")"
		printf 'ExecStop=%s -u %s\n' "$(sd_quote "$fusermount")" "$(sd_quote "$MOUNT_DIR")"
		printf '%s\n' "Restart=on-failure" "RestartSec=15" ""
		printf '%s\n' "[Install]" "WantedBy=default.target"
	} >"$unit.tmp"
	mv "$unit.tmp" "$unit"
	systemctl --user daemon-reload
	systemctl --user enable steadylink-mount.service >/dev/null 2>&1 || warn "could not enable steadylink-mount.service"
	systemctl --user restart steadylink-mount.service 2>/dev/null || true
	if systemctl --user is-active --quiet steadylink-mount.service; then
		ok "mounted $REMOTE: at $MOUNT_DIR"
	else
		warn "the mount service did not start. See: journalctl --user -u steadylink-mount -n 50"
	fi
	note "Starts at login (systemd user service steadylink-mount). Log: $LOG_DIR/mount.log"
}

setup_mount_macos() {
	fuse=0
	if [ -d /Library/Filesystems/macfuse.fs ] || [ -d /Library/Filesystems/fuse-t.fs ] || [ -e /usr/local/lib/libfuse-t.dylib ]; then
		fuse=1
	fi
	if [ "$fuse" = 1 ] && ! from_homebrew; then
		method=mount
		say "Found macFUSE or FUSE-T, so this uses rclone mount."
	else
		method=nfsmount
		say "rclone mount on macOS needs macFUSE or FUSE-T (and an rclone from rclone.org, since"
		say "Homebrew's build leaves mount out). This uses rclone nfsmount instead, which works"
		say "through the NFS client built into macOS and needs nothing else installed."
	fi
	pick_mount_dir || return 0
	encrypted_config_warning
	schedule='  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>30</integer>'
	set -- "$RCLONE" "$method" "$REMOTE:" "$MOUNT_DIR" --config "$CONFIG_FILE" \
		--vfs-cache-mode full --vfs-cache-max-age 24h --dir-cache-time 5m --log-level NOTICE
	if [ "$method" = mount ]; then set -- "$@" --volname SteadyLink; fi
	write_launch_agent io.steadylink.mount "$LOG_DIR/mount.log" "$schedule" "$@"
	sleep 3
	if mounted "$MOUNT_DIR"; then
		ok "mounted $REMOTE: at $MOUNT_DIR"
	else
		warn "not mounted yet. Check $LOG_DIR/mount.log in a few seconds."
	fi
	note "Starts at login (launchd agent io.steadylink.mount). Log: $LOG_DIR/mount.log"
}

# ---------------------------------------------------------------------------
# Scheduled backup

offer_backup() {
	step "Scheduled backup"
	say "This copies a local folder to a bucket on a schedule, logging each run."
	confirm "Set up a scheduled backup?" n || return 0

	while :; do
		ask "Folder to back up" "$HOME/Documents"
		src=$REPLY
		case "$src" in "~"/*) src="$HOME/${src#\~/}" ;; esac
		if [ -d "$src" ]; then
			src=$(cd "$src" && pwd -P)
			break
		fi
		warn "$src is not a folder."
	done

	default_bucket=$(printf '%s\n' "$BUCKETS" | sed -n 1p)
	while :; do
		ask "Bucket" "$default_bucket"
		bucket=$REPLY
		[ -n "$bucket" ] || continue
		if printf '%s\n' "$BUCKETS" | grep -qxF "$bucket"; then break; fi
		if confirm "Bucket '$bucket' was not in the list. Create it?" n; then
			if "$RCLONE" mkdir "$REMOTE:$bucket" </dev/null; then ok "created $bucket"; break; fi
			warn "could not create $bucket. Bucket names are 3 to 63 lowercase letters, digits and hyphens."
		fi
	done

	host=$(hostname 2>/dev/null | cut -d. -f1)
	ask "Folder inside the bucket" "$(slugify "${host:-computer}")/$(basename "$src")"
	dest_path=${REPLY#/}
	dest_path=${dest_path%/}
	dest="$REMOTE:$bucket/$dest_path"

	say ""
	say "  copy  uploads new and changed files. Files you delete locally stay in SteadyLink."
	say "  sync  makes the bucket folder match the local folder. Files deleted locally are"
	say "        moved to $bucket/.deleted/$dest_path instead of being removed."
	while :; do
		ask "Mode (copy or sync)" copy
		mode=$REPLY
		case "$mode" in copy | sync) break ;; esac
	done

	while :; do
		ask "Run daily at which hour (0-23), or 'hourly'" 2
		when=$REPLY
		case "$when" in
		hourly) break ;;
		[0-9] | 1[0-9] | 2[0-3]) break ;;
		esac
	done

	job=$(slugify "$(basename "$src")")
	[ -n "$job" ] || job=folder
	log="$LOG_DIR/backup-$job.log"
	encrypted_config_warning

	set -- "$RCLONE" "$mode" "$src" "$dest" --config "$CONFIG_FILE" \
		--log-file "$log" --log-level INFO --stats 0 \
		--exclude .DS_Store --exclude Thumbs.db --exclude desktop.ini
	if [ "$mode" = sync ]; then set -- "$@" --backup-dir "$REMOTE:$bucket/.deleted/$dest_path"; fi

	mkdir -p "$LOG_DIR"
	if [ "$OS" = Darwin ]; then
		if [ "$when" = hourly ]; then
			schedule='  <key>StartInterval</key><integer>3600</integer>'
		else
			schedule="  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>$when</integer><key>Minute</key><integer>0</integer></dict>"
		fi
		write_launch_agent "io.steadylink.backup.$job" "$log" "$schedule" "$@"
		ok "backup job io.steadylink.backup.$job installed"
		run_now="launchctl kickstart gui/$(id -u)/io.steadylink.backup.$job"
	else
		if ! has_systemd_user; then
			warn "no systemd user session here, so the job cannot be scheduled automatically."
			say "Add this to your crontab (crontab -e) instead:"
			cron_line=
			for arg in "$@"; do cron_line="$cron_line $(sh_quote "$arg")"; done
			# cron treats a bare % as a newline.
			cron_line=$(printf '%s' "$cron_line" | sed 's/%/\\%/g')
			if [ "$when" = hourly ]; then cron_hour='*'; else cron_hour=$when; fi
			printf '    0 %s * * *%s\n' "$cron_hour" "$cron_line"
			return 0
		fi
		mkdir -p "$UNIT_DIR"
		name="steadylink-backup-$job"
		exec_line="ExecStart="
		for arg in "$@"; do exec_line="$exec_line$(sd_quote "$arg") "; done
		{
			printf '%s\n' "[Unit]" "Description=SteadyLink backup of $(sd_text "$src") to $(sd_text "$dest")" "Documentation=$REPO_URL"
			printf '%s\n' "Wants=network-online.target" "After=network-online.target" ""
			printf '%s\n' "[Service]" "Type=oneshot" "Nice=10" "IOSchedulingClass=idle" "$exec_line"
		} >"$UNIT_DIR/$name.service.tmp"
		if [ "$when" = hourly ]; then calendar=hourly; else calendar="*-*-* $when:00:00"; fi
		{
			printf '%s\n' "[Unit]" "Description=Schedule for $name" ""
			printf '%s\n' "[Timer]" "OnCalendar=$calendar" "Persistent=true" "RandomizedDelaySec=5min" ""
			printf '%s\n' "[Install]" "WantedBy=timers.target"
		} >"$UNIT_DIR/$name.timer.tmp"
		mv "$UNIT_DIR/$name.service.tmp" "$UNIT_DIR/$name.service"
		mv "$UNIT_DIR/$name.timer.tmp" "$UNIT_DIR/$name.timer"
		systemctl --user daemon-reload
		if systemctl --user enable --now "$name.timer" >/dev/null 2>&1; then
			ok "backup timer $name.timer enabled"
		else
			warn "could not enable $name.timer. See: systemctl --user status $name.timer"
		fi
		run_now="systemctl --user start $name.service"
	fi
	note "Log: $log"
	note "Run it now: $run_now"
	if confirm "Run the first backup now, in the background?" n; then
		if [ "$OS" = Darwin ]; then
			launchctl kickstart "gui/$(id -u)/io.steadylink.backup.$job"
		else
			systemctl --user start --no-block "steadylink-backup-$job.service"
		fi
		ok "started. Follow it with: tail -f \"$log\""
	fi
}

# ---------------------------------------------------------------------------
# Uninstall

uninstall() {
	step "Removing SteadyLink mount and backup jobs"
	removed=0
	if [ "$OS" = Darwin ]; then
		for plist in "$AGENT_DIR"/io.steadylink.*.plist; do
			[ -e "$plist" ] || continue
			label=$(basename "$plist" .plist)
			remove_launch_agent "$label"
			ok "removed launchd agent $label"
			removed=1
		done
	elif [ -d "$UNIT_DIR" ]; then
		for unit in "$UNIT_DIR"/steadylink-*.timer "$UNIT_DIR"/steadylink-*.service; do
			[ -e "$unit" ] || continue
			name=$(basename "$unit")
			if have systemctl; then systemctl --user disable --now "$name" >/dev/null 2>&1 || true; fi
			rm -f "$unit"
			ok "removed $name"
			removed=1
		done
		if have systemctl; then systemctl --user daemon-reload 2>/dev/null || true; fi
	fi
	[ "$removed" = 1 ] || say "No mount or backup jobs found."

	if find_rclone; then
		load_config
		if [ -n "$(remote_type)" ] && confirm "Remove the rclone remote '$REMOTE' (and the key stored in it)?" n; then
			"$RCLONE" config delete "$REMOTE" </dev/null
			ok "removed remote '$REMOTE'"
		fi
		if confirm "Uninstall rclone itself?" n; then
			if from_homebrew; then
				brew uninstall rclone
			else
				case "$RCLONE" in
				"$HOME"/*) rm -f "$RCLONE" ;;
				*) as_root rm -f "$RCLONE" ;;
				esac
			fi
			ok "removed $RCLONE"
		fi
	fi
	say ""
	say "Files in SteadyLink and on this computer were not touched. Logs, if any, are in $LOG_DIR."
}

# ---------------------------------------------------------------------------

main() {
	if [ "$ACTION" = uninstall ]; then
		uninstall
		return 0
	fi

	say "${BOLD}SteadyLink rclone setup${RESET}"
	note "Endpoint $ENDPOINT, remote '$REMOTE'"

	ensure_rclone
	read_keys
	configure_remote
	if ! verify_remote; then
		exit 1
	fi

	if interactive; then
		offer_mount
		offer_backup
	fi

	step "Done"
	say "Try:"
	say "    rclone lsd $REMOTE:"
	say "    rclone copy ~/Pictures $REMOTE:my-bucket/pictures --progress"
	say ""
	say "Re-run this script any time to change the key, mount or backups."
	say "Remove the jobs with: curl -fsSL https://steadylink.io/install/rclone.sh | sh -s -- --uninstall"
	say "Docs: $REPO_URL"
}

main
