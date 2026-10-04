# Time365 Public Bootstrap

This public repository contains only the generic Time365 bootstrap entrypoint.
It contains no customer configuration, Docker registry credentials, application
secrets, database passwords, or private installer contents.

## Files

- `bootstrap.sh` - downloads/clones the private generic installer and launches a selected profile.

## Usage

Download the public bootstrap script on the Ubuntu target, then run it as the
normal SSH user (not with `sudo`; the script invokes sudo only for privileged
steps):

```bash
curl -fsSL https://raw.githubusercontent.com/<OWNER>/<PUBLIC-BOOTSTRAP-REPO>/main/bootstrap.sh -o /tmp/time365-bootstrap.sh
chmod +x /tmp/time365-bootstrap.sh

/tmp/time365-bootstrap.sh \
  --installer-repo git@github.com:<OWNER>/<PRIVATE-INSTALLER-REPO>.git \
  --profile dawami
```

For an HTTPS private repository URL, Git can prompt for GitHub credentials/PAT
through the terminal.

After a successful installation, the temporary clone of the private installer
is removed automatically. Use `--keep-installer` only when troubleshooting.
