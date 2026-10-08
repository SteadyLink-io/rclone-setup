# restic

[restic](https://restic.net) makes encrypted, deduplicated snapshots. It can store
them in SteadyLink through rclone, which restic starts and talks to on its own
(`rclone serve restic --stdio` under the hood). Set up the `steadylink` rclone
remote first, with the script in this repository or by hand.

restic's own S3 backend needs a bare hostname as the endpoint. SteadyLink's
dedicated S3 host, `s3.steadylink.io`, is not live yet, so use the rclone backend
below. Repositories created this way are ordinary restic repositories.

## Create a repository

```sh
export RESTIC_REPOSITORY=rclone:steadylink:my-bucket/restic
export RESTIC_PASSWORD_FILE=~/.config/restic/password   # keep a copy somewhere safe

restic init
```

The restic password encrypts the snapshots. SteadyLink never sees it, and without
it the backups cannot be read.

## Back up and restore

```sh
restic backup ~/Documents ~/Pictures
restic snapshots
restic restore latest --target ~/restore
```

Keep a reasonable history and remove the rest:

```sh
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune
```

## Notes

- Every restic pack file is an object, and each app key can make 600 writes a
  minute. restic opens 5 rclone connections by default, which stays well under
  that. If you see `SlowDown` in the output, lower it with
  `-o rclone.connections=2`.
- Use a key limited to the backup bucket. A read-only key is enough for
  `restic restore` on another machine.
- Deleting an object in SteadyLink removes its revisions too, so `restic prune`
  frees space straight away.
- Schedule `restic backup` with cron, a systemd timer or Task Scheduler the same
  way the setup script schedules rclone.
