# yon.

Big files, over there. Still in Finder.

Yon puts your Google Drive, OneDrive, Dropbox, Box, or any S3 bucket in Finder as a drive. Files stay in the cloud and take no space on your Mac. Open a 40 GB video and it starts playing in a second, because Yon fetches only the part being read.

Open source. No account with us. No storage bill from us. Your cloud, your quota.

## Install

Download `Yon.dmg` from the latest release, drag Yon to Applications, open it. It lives in the menu bar.

macOS 14 or newer, Apple silicon. Intel builds need an older SDK; see scripts/bundle.sh. No kernel extension, no Apple developer gate. If Gatekeeper complains, right-click Yon and choose Open once.

## Use

1. Menu bar arrow, Add Drive, pick a provider. Your browser opens, you sign in with the provider. The token stays on your Mac.
2. The drive appears in Finder under a location called `yon.local`, and at `~/Yon/<name>`. To have Finder call it plain `yon`, add this line to `/etc/hosts` once (needs your password) and Yon picks it up on the next mount:

   ```
   127.0.0.1 yon
   ```
3. Drag files in. Open them in any app. `cat`, `grep`, Final Cut, Claude Code, all see normal files.

Eject from the menu or Finder. Remove a drive from the menu when you no longer want it signed in on this Mac.

## How it works

Yon is a thin Swift menu-bar app around [rclone](https://rclone.org). Each drive is an rclone remote served with `rclone serve nfs` on a loopback port and mounted with the system `mount_nfs`, so nothing extra is installed. The hostname `yon.local` is published over Bonjour by Yon itself, pointing at 127.0.0.1, which is what Finder shows as the location. Reads are chunked and streamed. Writes are staged in `~/Library/Caches/rclone` and uploaded in the background.

Config lives in `~/Library/Application Support/Yon/rclone.conf`. Logs in `~/Library/Logs/Yon`.

The NFS server listens on 127.0.0.1 only, with no authentication beyond that, the same model FUSE-T uses. On a Mac shared by several user accounts, another signed-in user could reach a mounted drive. Yon assumes a single-user Mac.

## OAuth client IDs

Without configuration, sign-in uses rclone's shared Google and Microsoft client IDs. Google is retiring its shared one during 2026, so release builds should ship their own. Create a Google Cloud OAuth client (Desktop app) and an Azure app registration, then build with:

```sh
YON_GOOGLE_CLIENT_ID=… YON_GOOGLE_CLIENT_SECRET=… YON_MS_CLIENT_ID=… YON_MS_CLIENT_SECRET=… scripts/bundle.sh --dmg
```

The values are written into the app's Info.plist and never committed.

## Build

```sh
scripts/bundle.sh --dmg
```

Needs Command Line Tools and nothing else. `scripts/bundle.sh --dev` does a fast debug bundle using a Homebrew rclone.

## Not yet

End-to-end encryption (rclone `crypt`), share links, per-folder "keep on this Mac", upload progress in the menu. See issues.

MIT.
