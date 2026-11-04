# yon.

Big files, over there. Still in Finder.

Yon puts your Google Drive, OneDrive, Dropbox, Box, or any S3 bucket in Finder as a drive. Files stay in the cloud and take no space on your Mac. Open a 40 GB video and it starts playing in a second, because Yon fetches only the part being read.

Open source. No account with us. No storage bill from us. Your cloud, your quota.

## Install

Download `Yon.dmg` from the latest release, drag Yon to Applications, open it. It lives in the menu bar.

macOS 14 or newer, Apple silicon and Intel (one universal build). No kernel extension, no Apple developer gate. If Gatekeeper complains, right-click Yon and choose Open once.

## Use

1. Menu bar arrow, Add Drive, pick a provider. Your browser opens, you sign in with the provider. The token stays on your Mac.
2. The drive appears in Finder under a location called `yon.local`, and at `~/Yon/<name>`. To have Finder call it plain `yon`, add this line to `/etc/hosts` once (needs your password) and Yon picks it up on the next mount:

   ```
   127.0.0.1 yon
   ```
3. Drag files in. Open them in any app. `cat`, `grep`, Final Cut, Claude Code, all see normal files.

Eject from the menu or Finder. Remove a drive from the menu when you no longer want it signed in on this Mac.

## Encryption

Turn on "Encrypt this drive" when adding a drive and choose a password. File names and contents are then encrypted on your Mac before upload, so the provider stores only ciphertext. In Finder the drive works as before; in the provider's own web UI the files have scrambled names and unreadable contents. Encrypted drives show a lock in the menu.

The password is the only key. Yon does not keep a copy anywhere else, cannot recover it, and cannot reset it. If you lose it, the files are gone. The same password on another Mac running rclone or Yon reads the same files.

## How it works

Yon is a thin Swift menu-bar app around [rclone](https://rclone.org). Each drive is an rclone remote served with `rclone serve nfs` on a loopback port and mounted with the system `mount_nfs`, so nothing extra is installed. The hostname `yon.local` is published over Bonjour by Yon itself, pointing at 127.0.0.1, which is what Finder shows as the location. Reads are chunked and streamed. Writes are staged in `~/Library/Caches/rclone` and uploaded in the background.

Config lives in `~/Library/Application Support/Yon/rclone.conf`. Logs in `~/Library/Logs/Yon`.

An encrypted drive is two remotes: the provider remote under a hidden name (`<name> raw`) and a standard rclone [crypt](https://rclone.org/crypt/) remote with the drive's name wrapping it. The crypt remote is what gets served and mounted; removing the drive removes both. The format is rclone's, not Yon's: contents are encrypted in 64 KiB blocks with NaCl secretbox (XSalsa20-Poly1305), with a key derived from the password by scrypt. File and directory names are encrypted too (EME with AES, then base32), so the provider sees neither names nor contents, only sizes and modification times. Because each block is sealed on its own, reading the middle of a large file still fetches only the blocks being read. The password is stored obscured in rclone.conf, the same way rclone itself stores it; it is not in the Keychain and never leaves the Mac.

macOS stores extended attributes on NFS volumes in `._name` sidecar files, so those upload next to your files. They carry Finder tags and the `com.apple.quarantine` flag that Gatekeeper checks, so Yon keeps them rather than deleting them. Finder's `.DS_Store` view files can be switched off in Settings; that uses Apple's `DSDontWriteNetworkStores` preference and applies to every network drive on the Mac.

If Yon is force-quit, its rclone servers are cleaned up on the next launch.

The NFS server listens on 127.0.0.1 only, with no authentication beyond that, the same model FUSE-T uses. On a Mac shared by several user accounts, another signed-in user could reach a mounted drive. Yon assumes a single-user Mac.

## Updates

Yon checks `https://prantikmedhi.github.io/yon/appcast.xml` through Sparkle and asks before installing. Every release is signed with an EdDSA key whose public half is in the app; the private half exists only as the `SPARKLE_PRIVATE_KEY` repository secret. Check for Updates… is in the menu.

## OAuth client IDs

Without configuration, sign-in uses rclone's shared Google and Microsoft client IDs. Google is retiring its shared one during 2026, so release builds should ship their own. Create a Google Cloud OAuth client (Desktop app) and an Azure app registration, then build with:

```sh
YON_GOOGLE_CLIENT_ID=… YON_GOOGLE_CLIENT_SECRET=… YON_MS_CLIENT_ID=… YON_MS_CLIENT_SECRET=… scripts/bundle.sh --dmg
```

Releases are built by `.github/workflows/release.yml` on every `v*` tag, universal (Apple silicon and Intel), reading the same four names from repository secrets.

The values are written into the app's Info.plist and never committed.

## Build

```sh
scripts/bundle.sh --dmg
```

Needs Command Line Tools and nothing else. `scripts/bundle.sh --dev` does a fast debug bundle using a Homebrew rclone.

## Not yet

Share links, per-folder "keep on this Mac", encrypting a drive that already exists. See issues.

MIT.
