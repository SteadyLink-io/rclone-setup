# TrueNAS Cloud Sync

TrueNAS Cloud Sync tasks run rclone, so SteadyLink works with the path-style
endpoint. These steps are for TrueNAS SCALE and CORE; menu names differ a little
between versions.

## Add the credential

Go to **Credentials > Backup Credentials > Cloud Credentials** and choose **Add**.

| Field | Value |
| --- | --- |
| Provider | Amazon S3 |
| Name | SteadyLink |
| Access Key ID | your app key ID (starts with `SL`) |
| Secret Access Key | your app key secret |
| Endpoint URL | `https://api.steadylink.io/s3` (under **Advanced Settings**) |
| Region | `auto` |
| Disable Endpoint Region | off |
| Use Signature Version 2 | off |

Choose **Verify Credential**. A failure that mentions `InvalidAccessKeyId` or
`SignatureDoesNotMatch` means the key ID or secret is wrong; see the
[troubleshooting section](../README.md#troubleshooting).

## Create the task

Go to **Data Protection > Cloud Sync Tasks** and choose **Add**.

- **Direction**: Push. **Transfer Mode**: Copy to start with. Sync deletes files
  in SteadyLink that you delete on the NAS.
- **Credential**: SteadyLink. **Bucket**: pick one from the list.
- **Folder**: a folder inside the bucket, for example `truenas/photos`.
- **Directory/Files**: the dataset to back up.
- **Schedule**: daily is a good default.
- **Remote Encryption**: optional. It encrypts file contents and names with
  rclone crypt before upload. Files encrypted this way cannot be previewed or
  shared from the SteadyLink dashboard.

Under **Advanced Options**, keep **Transfers** at 4 or lower. Each app key can make
600 writes a minute.

Run the task once with **Dry Run** to check the file list, then start it.
