# rclone in Docker Compose

A container that copies one folder to SteadyLink every hour. Useful on a NAS,
a home server, or anything else that already runs Docker.

```sh
cp steadylink.env.example steadylink.env    # then put your app key in it
docker compose up -d
docker compose logs -f
```

Before starting it, edit `docker-compose.yml`:

- `volumes`: replace `/path/to/folder` with the folder to back up. It is mounted
  read-only, so the container cannot change it.
- `DEST`: `steadylink:<bucket>/<folder>`. The bucket must exist.
- `MODE`: `copy` (default) never deletes anything in SteadyLink. `sync` mirrors
  deletions, moving deleted files to `<bucket>/.deleted/<folder>` first.
- `INTERVAL_SECONDS`: time between runs.

The remote is defined with `RCLONE_CONFIG_STEADYLINK_*` environment variables, so
there is no rclone config file to mount. The key lives only in `steadylink.env`;
keep that file out of version control and readable only by you
(`chmod 600 steadylink.env`).

To run a different rclone command against the same remote:

```sh
docker compose run --rm --entrypoint rclone steadylink-backup lsd steadylink:
```
