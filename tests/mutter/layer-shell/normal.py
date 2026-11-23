#!/usr/bin/python3 -I
# SPDX-License-Identifier: Apache-2.0
"""An ordinary GTK 4 window for the layer-shell test: normal.py TITLE [--maximize]."""
import sys

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gtk  # noqa: E402


def activate(app):
    window = Gtk.ApplicationWindow(application=app, title=sys.argv[1])
    window.set_default_size(640, 400)
    if "--maximize" in sys.argv:
        window.maximize()
    window.present()


app = Gtk.Application(application_id="org.luma.test.LayerNormal")
app.connect("activate", activate)
app.run([])
