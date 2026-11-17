L16 Studio for the Light L16 camera
===================================

This package puts the L16 Studio app on a Light L16. The app adds:

  - a gallery of the shots on the camera, with a full-screen viewer
  - an editor: Auto, six looks (Vivid, Golden, Crisp, Film, Mono...) and
    sliders, saving a copy next to the shot
  - Wi-Fi transfer of shots to L16Studio on a Mac, or to any web browser
  - a button to Light's own camera app, which still takes the pictures
  - "Screen off" and lift to wake, for cameras whose power button has worn
    out: a button, and a second icon in the app list, put the camera to
    sleep, and picking it up or uncovering it wakes it. The camera asks you
    to allow the screen-off part the first time; it is the only special
    permission the app uses, and the uninstaller gives it back.

It is one ordinary Android app. The camera's own software is not changed,
nothing is rooted or flashed, and it can be removed again at any time.


What you need
-------------

  - A Light L16 that starts up normally
  - A USB-C data cable, plugged straight into the computer (not through a hub)
  - A Mac, Linux or Windows computer with an internet connection the first
    time (the installer downloads Google's "adb" tool if the computer doesn't
    have it; about 15 MB, kept in this folder)


Install
-------

  Mac:      double-click  install.command
            (if macOS refuses to open it: right-click > Open, once)
  Linux:    in a terminal:  ./install.sh
  Windows:  double-click  install.bat

The installer waits for the camera and tells you what to do on it. The one
thing only you can do is switch on "USB debugging", once per camera:

  1. On the camera: Settings > About > tap "Build number" seven times.
  2. Settings > Developer options > switch on "USB debugging".
  3. When the camera asks "Allow USB debugging?", tick
     "Always allow from this computer" and tap OK.

When it finishes, L16 Studio is open on the camera and in its app list.


Update or remove
----------------

  Update:   run the installer from a newer package; it installs over the top.
  Remove:   ./install.sh --uninstall      (Windows: install.bat -Uninstall)
            Your shots are not touched.

If the installer says the camera has a copy "from a different build", run it
with --replace (Windows: -Replace).


The Mac app
-----------

L16Studio for macOS reads the camera's raw files, fuses the lenses into one
image and imports from the camera by cable or Wi-Fi. Source and instructions:

  https://github.com/sunkencity999/L16Studio


Good to know
------------

  - Wi-Fi transfer is read-only and has no password. It only runs while you
    switch it on in the app; use it on a network you trust.
  - The editor works on the camera's 8-megapixel preview of each shot. The
    raw file is never changed.
  - This is community software for a camera whose maker no longer exists. It
    comes with no warranty; see the licence in the repository.
