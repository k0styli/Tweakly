# Security

## Supported versions

Only the latest release gets security fixes. Updates keep your settings and permissions, so there is no reason to stay on an older one.

## Reporting a vulnerability

Please don't open a public issue. Report it privately through **Security › Report a vulnerability** on this repository, with the steps to reproduce and what an attacker could gain. You'll get an answer within a few days, and credit in the release notes if you'd like it.

## What Tweakly can do on your Mac

Tweakly asks for each of these only when you turn on a feature that needs it. The Permissions page in its window shows every one, what uses it and whether it is given.

- **Accessibility.** Lets Tweakly read other apps' windows, bring one forward or minimize it, listen to Command-Tab, Fn and the mouse wheel, and turn the keyboard off while you clean it. Nothing you type is read or kept: the event taps look only at the keys their feature handles.
- **Screen & System Audio Recording.** Lets Window Switcher and Dock Previews take pictures of windows. Pictures stay in memory and are never written to disk or sent anywhere.
- **System Audio Recording Only.** Lets Volume Mixer change each app's volume as its sound plays. Nothing is recorded or kept.
- **Full Disk Access** (optional). Lets App Uninstaller measure and move the data App Store apps keep in their containers.
- **Files & Folders.** Lets New File in the Finder menu create a file on the desktop and in Documents and Downloads.

Parts that run apart from the app:

- **The helper** runs as root, and only after you install it with an administrator's password, for fan control and for other users' processes in Task Manager. It sets fan speeds, reads the figures of processes it is given and ends one process at a time after checking it is still the same process. It accepts calls only from code signed by the same Developer ID team as Tweakly.
- **The Finder extension** runs in the App Sandbox. It talks to Tweakly through a port that checks the code signature of every sender.
- **The media cleaner** is an XPC service in the App Sandbox with no network access. Every picture or video from outside goes through it, and it writes each one anew, before anything else in Tweakly reads it.
- **App Uninstaller** only moves files to the Trash, never deletes them. When it needs an administrator's password, it checks right before each move that the folder is still the one it scanned.

Tweakly has no analytics and no update server. It connects to the internet only to ask Cloudflare (`1.1.1.1`) for your public address while the network panel is open, and when you browse wallpaper sites in its browser.

Every release is signed with Developer ID and notarized by Apple.
