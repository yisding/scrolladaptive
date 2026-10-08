# scrolladaptive

Workaround for laggy or stalling trackpad scrolling in macOS guests running
under UTM's Apple Virtualization backend
([UTM #7531](https://github.com/utmapp/UTM/issues/7531)).

It drops empty scroll events and keeps the guest's compositor drawing while
you scroll. Run it **inside the guest**, not on the host.

## Install

In the guest, with the Command Line Tools installed (`xcode-select --install`):

```sh
./install.sh
```

This builds the tool and starts it at login. The first time, macOS asks for
Accessibility permission. Allow it in System Settings > Privacy & Security >
Accessibility. scrolladaptive waits and starts working as soon as you do.

Logs go to `~/Library/Logs/scrolladaptive.log`.

## Uninstall

```sh
./install.sh uninstall
```

## Run without installing

```sh
swiftc -O -target arm64-apple-macosx13.0 scrolladaptive.swift -o build/scrolladaptive
./build/scrolladaptive
```

Press Ctrl-C to quit and print statistics. When run from Terminal, the
Accessibility permission goes to Terminal rather than to scrolladaptive.

## Updating

Accessibility permission is tied to the exact binary. If an update changes the
binary, remove scrolladaptive from the Accessibility list and allow it again.
