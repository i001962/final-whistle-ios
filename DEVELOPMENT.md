# Developing Final Whistle

One command after a pull, on a Mac with Xcode 27.2 or later:

```sh
cd ~/Documents/final-whistle-ios
bash scripts/sim.sh
```

That pulls latest, discards Xcode's local reorder of `project.pbxproj`
(which used to abort the pull), builds for the simulator, and launches
the app. No development team is needed for the simulator: the build
runs with signing off. The iOS simulator runtime downloads itself on
first run if it is missing.

For a real phone (cable, unlocked, trusted, Developer Mode):

```sh
bash scripts/phone.sh
```

That one does need a team, selected once in Xcode under the target's
Signing & Capabilities, and it installs over the old copy without
wiping the Keychain (never uninstall the app to fix a problem — that
erases the stored keys).
