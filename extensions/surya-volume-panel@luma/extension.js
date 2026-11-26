// Surya Volume Panel — a Samsung-style per-role volume panel for Luma.
//
// One compact volume popup; tap the three dots to expand into separate
// vertical sliders for Media, Ring, Notification, System, Call and Alarm.
// Each slider drives one of Luma's role loopback sinks (or surya_media for
// Media), so they are independently touchable like One UI's Media panel.
//
// Built as an extension so it can be installed and iterated live on the
// phone; folded into the Luma shell once the look is final.

import GObject from 'gi://GObject';
import St from 'gi://St';
import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Volume from 'resource:///org/gnome/shell/ui/status/volume.js';

// St.BoxLayout's `vertical` was replaced by `orientation` in newer Clutter;
// set whichever this shell understands.
function setVertical(box) {
    try {
        box.orientation = Clutter.Orientation.VERTICAL;
    } catch (e) {
        try { box.vertical = true; } catch (e2) {}
    }
}

// Role -> sink name, label and icon. "Media" prefers our surya_media sink
// (what the volume keys drive); the rest are Luma's role loopbacks.
const ROLES = [
    {key: 'media',        label: 'Media',        icon: 'audio-headphones-symbolic',
     sinks: ['surya_media', 'input.loopback.sink.role.multimedia']},
    {key: 'ring',         label: 'Ring',         icon: 'audio-volume-high-symbolic',
     sinks: ['input.loopback.sink.role.ringtone']},
    {key: 'notification', label: 'Notification', icon: 'preferences-system-notifications-symbolic',
     sinks: ['input.loopback.sink.role.notification']},
    {key: 'system',       label: 'System',       icon: 'preferences-system-symbolic',
     sinks: ['input.loopback.sink.role.alert']},
    {key: 'call',         label: 'Call',         icon: 'call-start-symbolic',
     sinks: ['input.loopback.sink.role.phone']},
    {key: 'alarm',        label: 'Alarm',        icon: 'alarm-symbolic',
     sinks: ['input.loopback.sink.role.alarm']},
];

// A vertical pill slider: rounded track, fill from the bottom, icon at the
// foot, value label at the head. Tap or drag anywhere on the pill to set it.
const PillSlider = GObject.registerClass({
    Signals: {'value-changed': {param_types: [GObject.TYPE_DOUBLE]}},
}, class PillSlider extends St.BoxLayout {
    _init(role) {
        super._init({
            style_class: 'surya-vol-col',
            reactive: false,
            x_align: Clutter.ActorAlign.CENTER,
        });
        setVertical(this);
        this._role = role;
        this._value = 0;
        this._dragging = false;

        this._valueLabel = new St.Label({
            style_class: 'surya-vol-value',
            text: '',
            x_align: Clutter.ActorAlign.CENTER,
        });
        this.add_child(this._valueLabel);

        // The pill track; the fill is a child anchored to the bottom.
        this._track = new St.Widget({
            style_class: 'surya-vol-pill',
            reactive: true,
            can_focus: true,
            track_hover: true,
            y_expand: true,
            layout_manager: new Clutter.BinLayout(),
        });
        this._fill = new St.Widget({
            style_class: 'surya-vol-fill',
            y_align: Clutter.ActorAlign.END,
            x_expand: true,
        });
        this._icon = new St.Icon({
            style_class: 'surya-vol-icon',
            icon_name: role.icon,
            y_align: Clutter.ActorAlign.END,
            x_align: Clutter.ActorAlign.CENTER,
        });
        this._track.add_child(this._fill);
        this._track.add_child(this._icon);
        this.add_child(this._track);

        this._label = new St.Label({
            style_class: 'surya-vol-label',
            text: role.label,
            x_align: Clutter.ActorAlign.CENTER,
        });
        this.add_child(this._label);

        this._track.connect('button-press-event', (a, ev) => this._pointerDown(ev));
        this._track.connect('motion-event', (a, ev) => this._pointerMove(ev));
        this._track.connect('button-release-event', () => this._pointerUp());
        this._track.connect('touch-event', (a, ev) => this._touch(ev));
        this._track.connect('notify::height', () => this._updateFill());
    }

    _valueFromY(ev) {
        let [, ty] = this._track.get_transformed_position();
        let h = this._track.height;
        let [, y] = ev.get_coords();
        let frac = 1 - (y - ty) / h;
        return Math.max(0, Math.min(1, frac));
    }

    _pointerDown(ev) {
        this._dragging = true;
        this._setFromUser(this._valueFromY(ev));
        return Clutter.EVENT_STOP;
    }
    _pointerMove(ev) {
        if (this._dragging)
            this._setFromUser(this._valueFromY(ev));
        return Clutter.EVENT_PROPAGATE;
    }
    _pointerUp() {
        this._dragging = false;
        return Clutter.EVENT_STOP;
    }
    _touch(ev) {
        let t = ev.type();
        if (t === Clutter.EventType.TOUCH_BEGIN) {
            this._dragging = true;
            this._setFromUser(this._valueFromY(ev));
            return Clutter.EVENT_STOP;
        } else if (t === Clutter.EventType.TOUCH_UPDATE) {
            if (this._dragging)
                this._setFromUser(this._valueFromY(ev));
            return Clutter.EVENT_STOP;
        } else if (t === Clutter.EventType.TOUCH_END || t === Clutter.EventType.TOUCH_CANCEL) {
            this._dragging = false;
            return Clutter.EVENT_STOP;
        }
        return Clutter.EVENT_PROPAGATE;
    }

    _setFromUser(frac) {
        this.setValue(frac, true);
        this.emit('value-changed', frac);
    }

    setValue(frac, showLabel) {
        this._value = Math.max(0, Math.min(1, frac));
        this._updateFill();
        this._valueLabel.text = showLabel ? String(Math.round(this._value * 100)) : '';
    }

    _updateFill() {
        let h = this._track.height;
        if (h > 0)
            this._fill.height = Math.round(h * this._value);
    }

    setActiveLabel(active) {
        if (active)
            this._valueLabel.text = String(Math.round(this._value * 100));
    }
});

// The expanded panel: a titled, rounded container of pill sliders, shown
// centred with a dim backdrop that dismisses it. Mirrors One UI's Media panel.
const VolumePanel = GObject.registerClass(
class VolumePanel extends St.Widget {
    _init(mixer) {
        super._init({
            style_class: 'surya-vol-backdrop',
            reactive: true,
            visible: false,
            layout_manager: new Clutter.BinLayout(),
        });
        this._mixer = mixer;
        this._cols = [];
        this._streamHandlers = new Map();

        Main.layoutManager.addTopChrome(this);
        this.set_position(0, 0);
        this.set_size(global.stage.width, global.stage.height);

        this._card = new St.BoxLayout({
            style_class: 'surya-vol-card',
            x_align: Clutter.ActorAlign.CENTER,
            y_align: Clutter.ActorAlign.CENTER,
        });
        setVertical(this._card);
        this.add_child(this._card);

        this._title = new St.Label({style_class: 'surya-vol-title', text: 'Media'});
        this._card.add_child(this._title);

        this._row = new St.BoxLayout({style_class: 'surya-vol-row'});
        this._card.add_child(this._row);

        for (const role of ROLES) {
            let col = new PillSlider(role);
            col.connect('value-changed', (o, v) => this._applyVolume(role, v));
            this._row.add_child(col);
            this._cols.push({role, col});
        }

        // Tap outside the card closes the panel.
        this.connect('button-press-event', (a, ev) => {
            let [x, y] = ev.get_coords();
            let [cx, cy] = this._card.get_transformed_position();
            if (x < cx || y < cy || x > cx + this._card.width || y > cy + this._card.height)
                this.close();
            return Clutter.EVENT_STOP;
        });

        this._mixerChanged = this._mixer.connect('stream-added', () => this._refresh());
        this._mixerRemoved = this._mixer.connect('stream-removed', () => this._refresh());
    }

    _lookupSink(names) {
        let sinks = this._mixer.get_sinks();
        for (const name of names) {
            let hit = sinks.find(s => s.get_name() === name);
            if (hit)
                return hit;
        }
        return null;
    }

    _maxNorm() {
        return this._mixer.get_vol_max_norm();
    }

    _applyVolume(role, frac) {
        let stream = this._lookupSink(role.sinks);
        if (!stream)
            return;
        stream.volume = Math.round(frac * this._maxNorm());
        stream.push_volume();
    }

    _refresh() {
        // Drop old notify handlers.
        for (const [stream, id] of this._streamHandlers)
            try { stream.disconnect(id); } catch (e) {}
        this._streamHandlers.clear();

        let max = this._maxNorm();
        for (const {role, col} of this._cols) {
            let stream = this._lookupSink(role.sinks);
            if (stream) {
                col.setValue(stream.volume / max, false);
                col.visible = true;
                let id = stream.connect('notify::volume', () => {
                    if (!col._dragging)
                        col.setValue(stream.volume / max, false);
                });
                this._streamHandlers.set(stream, id);
            } else {
                col.visible = false;
            }
        }
    }

    open() {
        this._refresh();
        this.set_size(global.stage.width, global.stage.height);
        this.visible = true;
        this._grab = Main.pushModal(this);
    }

    close() {
        if (this._grab) {
            Main.popModal(this._grab);
            this._grab = null;
        }
        this.visible = false;
    }

    destroy() {
        this.close();
        if (this._mixerChanged) this._mixer.disconnect(this._mixerChanged);
        if (this._mixerRemoved) this._mixer.disconnect(this._mixerRemoved);
        for (const [stream, id] of this._streamHandlers)
            try { stream.disconnect(id); } catch (e) {}
        this._streamHandlers.clear();
        super.destroy();
    }
});

const DBUS_IFACE = `
<node>
  <interface name="org.luma.SuryaVolume">
    <method name="Toggle"/>
    <method name="Open"/>
    <method name="Close"/>
  </interface>
</node>`;

export default class SuryaVolumePanelExtension extends Extension {
    enable() {
        this._mixer = Volume.getMixerControl();
        this._panel = new VolumePanel(this._mixer);

        // Test/trigger over D-Bus (reliable regardless of top-bar layout):
        //   gdbus call --session -d org.luma.SuryaVolume \
        //     -o /org/luma/SuryaVolume -m org.luma.SuryaVolume.Toggle
        // The final build opens it from the three-dots on the volume popup.
        this._ownerId = Gio.bus_own_name(
            Gio.BusType.SESSION, 'org.luma.SuryaVolume',
            Gio.BusNameOwnerFlags.NONE,
            (conn) => {
                this._dbus = Gio.DBusExportedObject.wrapJSObject(DBUS_IFACE, this);
                this._dbus.export(conn, '/org/luma/SuryaVolume');
            },
            null, null);

        // Also try a top-bar button (harmless if the layout hides it).
        try {
            this._button = new St.Button({
                style_class: 'panel-button',
                child: new St.Icon({icon_name: 'audio-volume-high-symbolic', style_class: 'system-status-icon'}),
                can_focus: true,
            });
            this._button.connect('clicked', () => this.Toggle());
            Main.panel._rightBox.insert_child_at_index(this._button, 0);
        } catch (e) {}
    }

    Toggle() {
        if (this._panel.visible)
            this._panel.close();
        else
            this._panel.open();
    }
    Open() { this._panel.open(); }
    Close() { this._panel.close(); }

    disable() {
        if (this._dbus) {
            this._dbus.unexport();
            this._dbus = null;
        }
        if (this._ownerId) {
            Gio.bus_unown_name(this._ownerId);
            this._ownerId = 0;
        }
        if (this._button) {
            this._button.destroy();
            this._button = null;
        }
        if (this._panel) {
            this._panel.destroy();
            this._panel = null;
        }
        this._mixer = null;
    }
}
