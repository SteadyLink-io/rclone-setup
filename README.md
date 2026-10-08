# rclone setup for SteadyLink

Scripts that install [rclone](https://rclone.org), connect it to your SteadyLink
workspace with an app key, and optionally mount your buckets as a drive or back up
a folder on a schedule.

macOS and Linux:

```sh
curl -fsSL https://steadylink.io/install/rclone.sh | sh
```

Windows (PowerShell):

```powershell
irm https://steadylink.io/install/rclone.ps1 | iex
```

The script asks for your access key ID and secret. To skip the prompts, pass them
in the environment. This is the command the dashboard shows when you create a key:

```sh
curl -fsSL https://steadylink.io/install/rclone.sh | STEADYLINK_ACCESS_KEY_ID=SL... STEADYLINK_SECRET_ACCESS_KEY=... sh
```

```powershell
$env:STEADYLINK_ACCESS_KEY_ID='SL...'; $env:STEADYLINK_SECRET_ACCESS_KEY='...'; irm https://steadylink.io/install/rclone.ps1 | iex
```

The files served from steadylink.io are copies of [`install.sh`](install.sh) and
[`install.ps1`](install.ps1) in this repository. Read them before you run them;
they are plain shell and PowerShell with no downloaded helpers.

## What the script does

1. **Checks for rclone 1.65 or newer** and installs or upgrades it if needed:
   - Windows: `winget install Rclone.Rclone`. Without winget, it downloads the
     release zip from downloads.rclone.org, checks it against the published
     `SHA256SUMS`, and puts `rclone.exe` in `%LOCALAPPDATA%\Programs\rclone`.
   - macOS: Homebrew if you have it, otherwise rclone's official installer
     (`https://rclone.org/install.sh`).
   - Linux: rclone's official installer, using `sudo` only if you are not root.
     Without root or sudo, it downloads and checksums the release zip and installs
     to `~/.local/bin`.
2. **Creates an rclone remote** called `steadylink` with `rclone config create`.
   If a remote with that name exists, it asks before replacing its settings. The
   key is stored in rclone's own config file and never printed.
3. **Checks the key** by running `rclone lsd steadylink:` and lists the buckets it
   can see. If the key is wrong, it says why in plain words (unknown key ID, wrong
   secret, revoked key, clock off, network blocked).
4. **Offers to mount SteadyLink** as a drive (Windows) or folder (macOS, Linux)
   that comes back each time you log in. Default answer is no.
5. **Offers a scheduled backup** of one local folder to a bucket, daily or hourly,
   with a log file. Default answer is no.

Steps 4 and 5 only run in an interactive terminal. Re-running the script is safe:
it updates what is already there instead of adding duplicates.

### Options

| Variable | Default | Meaning |
| --- | --- | --- |
| `STEADYLINK_ACCESS_KEY_ID` | | App key ID, starts with `SL` |
| `STEADYLINK_SECRET_ACCESS_KEY` | | App key secret |
| `STEADYLINK_ENDPOINT` | `https://api.steadylink.io/s3` | S3 endpoint |
| `STEADYLINK_REMOTE` | `steadylink` | Name of the rclone remote |
| `STEADYLINK_NONINTERACTIVE` | | Set to `1` to configure the remote and stop. No prompts. |

On macOS and Linux the same options exist as flags: `--non-interactive`,
`--remote NAME`, `--uninstall`. Pass them after `sh -s --`:

```sh
curl -fsSL https://steadylink.io/install/rclone.sh | sh -s -- --remote work
```

In PowerShell, switches need the script block form:

```powershell
& ([scriptblock]::Create((irm https://steadylink.io/install/rclone.ps1))) -Remote work
```

## Getting an app key

App keys belong to you in one workspace and act with your role. A key can be
read-only, or limited to a single bucket. The secret is shown once, when the key
is created. See the [S3 API reference](https://steadylink.io/docs/reference/s3#app-keys)
for how to create one.

## Manual setup

You do not need the script. With rclone 1.65 or newer installed:

```sh
rclone config create steadylink s3 \
  provider=Other \
  access_key_id=SLXXXXXXXXXXXXXXXXXX \
  secret_access_key=YOUR_SECRET \
  endpoint=https://api.steadylink.io/s3 \
  region=auto \
  force_path_style=true
```

Or add this to `rclone.conf` (`rclone config file` prints its location):

```ini
[steadylink]
type = s3
provider = Other
access_key_id = SLXXXXXXXXXXXXXXXXXX
secret_access_key = YOUR_SECRET
endpoint = https://api.steadylink.io/s3
region = auto
force_path_style = true
```

Then:

```sh
rclone lsd steadylink:                                  # list buckets
rclone copy ~/Pictures steadylink:my-bucket/pictures --progress
rclone sync ~/Documents steadylink:my-bucket/documents
rclone check ~/Documents steadylink:my-bucket/documents
```

Uploading a file that already exists adds a new revision behind the same stable
link, so published `cdn.steadylink.io` links keep serving the latest version.
rclone stores modification times in object metadata, so `sync` and `check` do not
re-upload unchanged files.

## Mounting

The script sets this up for you. What it does on each system:

**Windows.** rclone needs [WinFsp](https://winfsp.dev). The script offers to
install it with `winget install WinFsp.WinFsp` (Windows asks for permission), then
mounts on the first free letter starting at `S:`. A Task Scheduler entry called
`SteadyLink Mount` runs this at sign-in:

```powershell
rclone mount steadylink: S: --vfs-cache-mode full --network-mode --no-console
```

**macOS.** `rclone mount` needs [macFUSE](https://osxfuse.github.io) or
[FUSE-T](https://www.fuse-t.org), and Homebrew's rclone is built without it.
If neither is set up, the script uses `rclone nfsmount` instead, which goes
through the NFS client built into macOS and needs nothing extra. It mounts at
`~/SteadyLink` and adds a launchd agent, `io.steadylink.mount`.

**Linux.** Needs FUSE (`fuse3` package). The script mounts at `~/SteadyLink`
through a systemd user service, `steadylink-mount.service`. Without systemd (WSL,
containers) it prints the command to run by hand.

`--vfs-cache-mode full` keeps a local cache so programs can open, seek and edit
files as they would on a normal disk. Changes upload in the background shortly
after a file is closed. The cache lives in rclone's cache directory and old
entries are dropped after 24 hours.

## Scheduled backup

The script asks for a folder, a bucket, a folder inside the bucket (default
`<computer-name>/<folder>`), a mode and a time.

- `copy` uploads new and changed files. Deleting a file locally does not delete it
  in SteadyLink. This is the default.
- `sync` makes the bucket folder match the local one. Files you delete locally are
  moved to `<bucket>/.deleted/<path>` with `--backup-dir` rather than removed, so
  a mistake can be undone.

| System | Scheduler | Log |
| --- | --- | --- |
| Windows | Task Scheduler, `SteadyLink Backup <name>` | `%LOCALAPPDATA%\SteadyLink\logs\backup-<name>.log` |
| macOS | launchd, `io.steadylink.backup.<name>` | `~/Library/Logs/SteadyLink/backup-<name>.log` |
| Linux | systemd user timer, `steadylink-backup-<name>.timer` | `~/.local/state/steadylink/backup-<name>.log` |

A run missed while the computer was asleep starts when it wakes. On Windows the
task runs a short script in `%LOCALAPPDATA%\SteadyLink\jobs` that you can read or
edit. Jobs only run while you are logged in. On Linux, `loginctl enable-linger`
lets the timer run without a session.

To back up more than one folder, run the script again and pick another folder.

## Uninstall

```sh
curl -fsSL https://steadylink.io/install/rclone.sh | sh -s -- --uninstall
```

```powershell
& ([scriptblock]::Create((irm https://steadylink.io/install/rclone.ps1))) -Uninstall
```

This stops and removes the mount and backup jobs the script created. It then asks
whether to remove the `steadylink` remote and whether to uninstall rclone; both
default to no. It never deletes files, in SteadyLink or on your computer. Logs
stay where they are. WinFsp stays installed on Windows
(`winget uninstall WinFsp.WinFsp` removes it).

## Troubleshooting

**InvalidAccessKeyId.** SteadyLink does not know the key ID. Check it was copied in
full and starts with `SL`, and that the key has not been revoked.

**SignatureDoesNotMatch.** The key ID is right but the secret is not. Copy it again
without spaces or line breaks. Secrets cannot be shown again; create a new key if
you have lost it.

**AccessDenied.** The key was revoked, its owner left the workspace, or the key is
read-only and you tried to write. An `AccessDenied` that mentions "Upload blocked"
means the file was rejected by a malware scan or by the bucket's file type or size
rules.

**QuotaExceeded.** The workspace has used its storage allowance.

**RequestTimeTooSkewed.** Your clock is more than a few minutes off. Turn on
automatic time.

**SlowDown.** Each key can make 1200 reads and 600 writes a minute. rclone retries
on its own. For large syncs, `--transfers 4 --checkers 8` lowers the request rate.

**The drive does not appear (Windows).** Check `%LOCALAPPDATA%\SteadyLink\logs\mount.log`.
"cannot find winfsp" means WinFsp is missing. Run the task by hand with
`Start-ScheduledTask 'SteadyLink Mount'`.

**Mount fails on Linux with "fusermount: not found".** Install `fuse3`.

**`rclone: command not found` after install.** Open a new terminal. On Linux
without sudo, add `~/.local/bin` to your `PATH`.

## Security notes

- The secret is stored in rclone's config file in your home directory, the same
  way rclone stores every other remote. To encrypt that file, run
  `rclone config encryption set`. Mount and backup jobs then need the password;
  see `--password-command` in the rclone docs.
- Mount and backup jobs refer to the remote by name. The secret is not written
  into Task Scheduler, launchd plists or systemd units.
- The secret is passed to `rclone config create` once, as an argument, so it is
  briefly visible to other users of the same computer in the process list.
- A key pasted into a one-line command ends up in your shell history. Running the
  script without the variables and typing the secret at the prompt avoids that.
- Create a separate key for each computer or NAS, and make it read-only or limit it
  to one bucket when that is enough. Revoking one key then affects one machine.
- The scripts send nothing anywhere except to rclone's download servers (to
  install it) and to your SteadyLink endpoint. There is no telemetry.

## Recipes

- [restic backups](recipes/restic.md)
- [Synology DSM](recipes/synology.md)
- [TrueNAS Cloud Sync](recipes/truenas.md)
- [rclone in Docker Compose](recipes/docker-compose/)

## License

MIT. See [LICENSE](LICENSE).
