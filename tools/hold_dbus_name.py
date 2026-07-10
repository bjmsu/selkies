#!/usr/bin/env python3
"""Claim a D-Bus name on the session bus and idle forever.

Used by run.sh inside the virtual desktop's private session bus: kded6
endlessly re-activates org.bluez.obex there (obexd exits immediately in a
second same-user session), and that activation loop kept dbus-daemon and
evolution-addressbook-factory spinning at ~10% CPU each. Holding the name
satisfies kded6 and ends the loop; the only casualty is Bluetooth OBEX file
transfer, which the virtual desktop does not need. The xrdp session's bus is
unaffected.
"""
import sys

from gi.repository import Gio, GLib

name = sys.argv[1] if len(sys.argv) > 1 else "org.bluez.obex"
Gio.bus_own_name(Gio.BusType.SESSION, name, Gio.BusNameOwnerFlags.NONE,
                 None, None, None)
GLib.MainLoop().run()
