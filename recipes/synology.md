# Synology DSM

Synology's own S3 clients, Cloud Sync and Hyper Backup, take a server hostname but
no path. SteadyLink's S3 API currently lives at a path, `https://api.steadylink.io/s3`,
and the dedicated hostname `s3.steadylink.io` is not live yet. Until it is, run
rclone in Container Manager instead.

## Now: rclone in Container Manager

1. Install **Container Manager** from Package Center.
2. Create a folder for the project, for example `/volume1/docker/steadylink`, and
   copy [`docker-compose.yml`](docker-compose/docker-compose.yml) and
   [`steadylink.env.example`](docker-compose/steadylink.env.example) into it.
   Rename the second file to `steadylink.env` and put your app key in it.
3. In `docker-compose.yml`, change the volume to the shared folder you want to back
   up (for example `/volume1/photo:/data:ro`) and set `DEST` to your bucket and
   folder.
4. In Container Manager, open **Project**, choose **Create**, pick the folder, and
   start it.

The container runs `rclone copy` once an hour and logs to the container's output,
which Container Manager shows under **Log**. See the
[Docker Compose recipe](docker-compose/) for the details and for switching to
`sync`.

## Later: Cloud Sync and Hyper Backup

When `s3.steadylink.io` is live, both apps will connect directly. The settings
will be:

| Field | Value |
| --- | --- |
| S3 server | **Custom server URL** |
| Server address | `s3.steadylink.io` |
| Signature version | v4 |
| Request style | Path style (Hyper Backup) |
| Region | `auto`, or leave empty |
| Access key / Secret key | your app key |
| Bucket | an existing bucket name, as shown by `rclone lsd steadylink:` |

This page will say so when the host is available.
