# Security Policy

Dynamo installs a small service that runs as root to control charging, so security
reports are taken seriously.

## Supported versions

Only the latest release receives fixes. Dynamo checks for updates daily and can update
itself from the panel.

## Reporting a vulnerability

Please **don't open a public issue** for security problems. Instead, report them
privately through GitHub: **Security → Report a vulnerability** on this repository.
You'll get a reply within a few days.

## What the installer does

`install.sh` (or `dynamo-setup` for Homebrew) only:

- builds Dynamo from this source with Apple's Swift compiler (no downloads)
- copies `dynamo` to `/Library/Application Support/Dynamo/` and registers it with
  launchd as `io.github.arshdwani.dynamo`
- creates `/Library/Application Support/Dynamo/config.json` (writable by your user)
- adds a log rotation rule in `/etc/newsyslog.d/dynamo.conf`
- copies `Dynamo.app` to `/Applications`

The root service only reads battery state and writes the SMC charging keys (`CHTE`,
`CHIE`, `ACLC`), and runs `pmset` for Low Power Mode. The app's only network request is
the optional daily update check against GitHub's public releases API.
`./uninstall.sh` removes all of it and hands charging back to macOS.
