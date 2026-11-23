// SPDX-License-Identifier: Apache-2.0
// gnome-shell --automation-script for the layer-shell test (run.sh): real
// zwlr_layer_shell_v1 clients (client.c) against the Mutter under test.
// Checks the arrangement, exclusive zones and the work area, stacking, the
// capability clamps, the overdraw limits, keyboard rules, hiding, popups and
// protocol errors. The client is a host client; its application ID is its
// executable's name.
import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const out = GLib.getenv('LUMA_LAYER_OUT');
const client = GLib.getenv('LUMA_LAYER_CLIENT');
const normalWindow = GLib.getenv('LUMA_LAYER_NORMAL');
const APP = 'layer-test-client';
const Cap = {BACKGROUND: 1, PANEL: 2, OVERLAY: 4, KEYBOARD: 8};
const results = [];
const shots = [];

const compositor = global.context.get_wayland_compositor();
const seat = Clutter.get_default_backend().get_default_seat();
const virtualKeyboard = seat.create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
const virtualPointer = seat.create_virtual_device(Clutter.InputDeviceType.POINTER_DEVICE);
const overlayGroup = global.compositor.get_layer_overlay_group();

const sleep = ms => new Promise(resolve => GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => {
    resolve();
    return GLib.SOURCE_REMOVE;
}));
const check = (name, ok, detail = '') => {
    results.push({name, ok: !!ok, detail: String(detail)});
    console.log(`${ok ? 'PASS' : 'FAIL'} ${name} ${detail}`);
};
const rect = w => {
    const r = w.get_frame_rect();
    return {x: r.x, y: r.y, width: r.width, height: r.height};
};
function anyReactive(actor) {
    if (!actor)
        return false;
    if (actor.constructor.name.includes('SurfaceActor') && actor.reactive)
        return true;
    return actor.get_children().some(anyReactive);
}
const workArea = () => {
    const r = global.workspace_manager.get_active_workspace().get_work_area_for_monitor(0);
    return {x: r.x, y: r.y, width: r.width, height: r.height};
};

async function screenshot(name) {
    const file = Gio.File.new_for_path(`${out}/${name}.png`);
    const stream = file.replace(null, false, Gio.FileCreateFlags.NONE, null);
    const shooter = new Shell.Screenshot();
    await new Promise((resolve, reject) => shooter.screenshot(false, stream, (o, res) => {
        try {
            o.screenshot_finish(res);
            resolve();
        } catch (e) {
            reject(e);
        }
    }));
    stream.close(null);
    shots.push(name);
}

let serial = 0;
class Client {
    constructor(args) {
        this.name = `c${++serial}`;
        this.log = `${out}/${this.name}.log`;
        const launcher = new Gio.SubprocessLauncher({flags: Gio.SubprocessFlags.STDERR_MERGE});
        launcher.set_stdout_file_path(this.log);
        this.proc = launcher.spawnv([client, '--namespace', this.name, ...args]);
        this.pid = Number(this.proc.get_identifier());
    }

    lines() {
        try {
            const [, bytes] = GLib.file_get_contents(this.log);
            return new TextDecoder().decode(bytes).split('\n').filter(Boolean);
        } catch {
            return [];
        }
    }

    has(prefix) {
        return this.lines().some(l => l.startsWith(prefix));
    }

    async waitFor(prefix, ms = 4000) {
        for (let t = 0; t < ms; t += 50) {
            if (this.has(prefix))
                return true;
            await sleep(50);
        }
        return false;
    }

    window() {
        return global.display.list_all_windows().find(w => w.get_pid() === this.pid &&
            (w.get_window_type() === Meta.WindowType.DOCK ||
             w.get_window_type() === Meta.WindowType.DESKTOP)) ?? null;
    }

    async waitWindow(ms = 4000) {
        for (let t = 0; t < ms; t += 50) {
            const w = this.window();
            if (w && w.get_frame_rect().width > 0)
                return w;
            await sleep(50);
        }
        return null;
    }

    actor() {
        return this.window()?.get_compositor_private() ?? null;
    }

    kill() {
        this.proc.force_exit();
    }
}

function spawnNormal(title, extra = []) {
    const launcher = new Gio.SubprocessLauncher({flags: Gio.SubprocessFlags.STDERR_MERGE});
    launcher.setenv('GDK_BACKEND', 'wayland', true);
    launcher.set_stdout_file_path(`${out}/${title}.log`);
    return launcher.spawnv(['python3', normalWindow, title, ...extra]);
}

async function waitTitle(title) {
    for (let t = 0; t < 8000; t += 100) {
        const w = global.display.list_all_windows().find(x => x.get_title() === title);
        if (w && w.get_frame_rect().width > 0)
            return w;
        await sleep(100);
    }
    return null;
}

async function ensureDesktop() {
    for (let i = 0; i < 20 && (Main.overview.visible || Main.overview.animationInProgress); i++) {
        Main.overview.hide();
        await sleep(300);
    }
}

async function run() {
    await ensureDesktop();
    // Headless Mutter has no keymap until a keyboard exists; a client that
    // binds wl_keyboard before that crashes it in send_keymap().
    await sleep(2000);
    const monitor = global.display.get_monitor_geometry(0);
    const base = workArea();
    check('virtual monitor', monitor.width === 1920 && monitor.height === 1080,
        `${monitor.width}x${monitor.height}`);

    // 1. A bar: stretched along the top, exclusive zone 30.
    const bar = new Client(['--layer', 'top', '--anchor', 'tlr', '--size', '0x30',
        '--zone', '30', '--colour', '3355cc']);
    check('bar binds v5', await bar.waitFor('bound 5'), bar.lines().join('|'));
    check('bar configured to the monitor width', await bar.waitFor('configure 1920 30'),
        bar.lines().join('|'));
    const barWindow = await bar.waitWindow();
    check('bar is a dock window', barWindow?.get_window_type() === Meta.WindowType.DOCK);
    check('bar at the top of the work area', barWindow && rect(barWindow).y === base.y &&
        rect(barWindow).width === 1920 && rect(barWindow).height === 30,
    JSON.stringify(barWindow && rect(barWindow)));
    await sleep(300);
    check('work area starts below the bar', workArea().y === base.y + 30,
        `${JSON.stringify(base)} -> ${JSON.stringify(workArea())}`);
    check('bar skips the taskbar', barWindow?.is_skip_taskbar());

    // 2. A maximized window respects it.
    spawnNormal('normal-a', ['--maximize']);
    const normal = await waitTitle('normal-a');
    await sleep(800);
    check('maximized window below the bar', normal && rect(normal).y >= base.y + 30,
        JSON.stringify(normal && rect(normal)));

    // 3. A second bar on the same edge stacks below the first.
    const bar2 = new Client(['--layer', 'top', '--anchor', 'tlr', '--size', '0x20',
        '--zone', '20', '--margin', '4,0,0,0']);
    const bar2Window = await bar2.waitWindow();
    await sleep(300);
    check('second bar stacks under the first', bar2Window && rect(bar2Window).y === base.y + 30 + 4,
        JSON.stringify(bar2Window && rect(bar2Window)));
    check('work area takes both zones', workArea().y === base.y + 30 + 4 + 20, JSON.stringify(workArea()));
    bar2.kill();
    await sleep(500);
    check('work area back after the second bar goes', workArea().y === base.y + 30, JSON.stringify(workArea()));

    // 4. Corner anchor with an explicit exclusive edge (v5).
    const corner = new Client(['--layer', 'top', '--anchor', 'tl', '--size', '50x50',
        '--zone', '50', '--edge', 'l']);
    await corner.waitWindow();
    await sleep(300);
    check('exclusive edge reserves the left edge', workArea().x === base.x + 50, JSON.stringify(workArea()));
    corner.kill();
    await sleep(300);

    // 5. Stacking: background below, top above the normal window.
    const bg = new Client(['--layer', 'background', '--anchor', 'tblr', '--size', '0x0',
        '--colour', '223322']);
    const bgWindow = await bg.waitWindow();
    const children = global.window_group.get_children();
    const index = w => children.indexOf(w?.get_compositor_private());
    check('background surface is a desktop window', bgWindow?.get_window_type() === Meta.WindowType.DESKTOP);
    check('background below the normal window', index(bgWindow) >= 0 && index(bgWindow) < index(normal),
        `${index(bgWindow)} < ${index(normal)}`);
    check('top above the normal window', index(barWindow) > index(normal),
        `${index(barWindow)} > ${index(normal)}`);
    check('background exempt from the limits', bg.actor()?.opacity === 255);
    await screenshot('bar-background-maximized');

    // 6. Overlay without OVERLAY: clamped to top. Keyboard exclusive without
    //    KEYBOARD: on demand, no focus when it maps.
    normal.activate(global.get_current_time());
    await sleep(300);
    const clamped = new Client(['--layer', 'overlay', '--anchor', 'tr', '--size', '300x200',
        '--keyboard', 'exclusive', '--colour', 'cc8800']);
    await clamped.waitWindow();
    await sleep(500);
    check('overlay without the grant goes on top',
        clamped.actor()?.get_parent() === global.window_group, clamped.actor()?.get_parent()?.name);
    check('exclusive keyboard without the grant: no focus on map', !clamped.has('keyboard-enter'),
        clamped.lines().join('|'));
    check('no overlay indicator for a top surface',
        compositor.get_layer_shell_overlay_apps().length === 0);
    clamped.kill();
    await sleep(300);

    // 7. Granted: overlay above windows, exclusive keyboard focused.
    compositor.set_layer_shell_grants(APP, Cap.OVERLAY | Cap.KEYBOARD, 0);
    const overlay = new Client(['--layer', 'overlay', '--anchor', 'tr', '--size', '300x200',
        '--keyboard', 'exclusive', '--colour', '00aa88']);
    await overlay.waitWindow();
    check('granted overlay in the overlay group', overlay.actor()?.get_parent() === overlayGroup);
    check('granted exclusive keyboard focused on map', await overlay.waitFor('keyboard-enter'),
        overlay.lines().join('|'));
    normal.activate(global.get_current_time());
    await sleep(400);
    check('exclusive surface keeps the keyboard', global.display.focus_window === overlay.window(),
        global.display.focus_window?.get_title());
    check('overlay app reported', compositor.get_layer_shell_overlay_apps().includes(APP),
        compositor.get_layer_shell_overlay_apps().join(','));
    await screenshot('overlay-granted');

    // 8. Hidden while locked: not shown, keyboard gone; back after.
    compositor.set_layer_surfaces_hidden(true);
    await sleep(400);
    check('hidden: overlay not shown', !overlay.actor()?.visible);
    check('hidden: bar not shown', !bar.actor()?.visible);
    check('hidden: no layer surface has the keyboard',
        global.display.focus_window !== overlay.window());
    check('hidden: no overlay indicator', compositor.get_layer_shell_overlay_apps().length === 0);
    compositor.set_layer_surfaces_hidden(false);
    await sleep(400);
    check('shown again', overlay.actor()?.visible && bar.actor()?.visible);
    overlay.kill();
    await sleep(300);

    // 9. Startup guard: a full-screen overlay right after start is refused.
    const phish = new Client(['--layer', 'overlay', '--anchor', 'tblr', '--size', '0x0',
        '--colour', 'ffffff']);
    check('full-screen overlay at start is refused', await phish.waitFor('closed'),
        phish.lines().join('|'));

    // 10. A full-screen overlay later: dimmed unless it has its turn.
    const big = new Client(['--layer', 'top', '--anchor', 'tblr', '--size', '0x0',
        '--colour', '8844aa', '--set-layer-after-ms', 'overlay:2600']);
    await big.waitFor('set-layer', 6000);
    await sleep(500);
    normal.activate(global.get_current_time());
    await sleep(400);
    const bigActor = big.actor();
    check('big overlay mapped after the guard', bigActor?.get_parent() === overlayGroup,
        big.lines().join('|'));
    check('big overlay faded to 0.35 while another app has the focus', bigActor?.opacity === 89,
        bigActor?.opacity);
    check('faded overlay is desaturated', !!bigActor?.get_effect('luma-layer-fade'));
    check('faded overlay lets input through', bigActor && !anyReactive(bigActor));
    check('faded app reported', compositor.get_layer_shell_dimmed_apps().includes(APP));
    await screenshot('overlay-dimmed');
    normal.make_fullscreen();
    await sleep(800);
    normal.activate(global.get_current_time());
    await sleep(400);
    check('big overlay shown over a focused full-screen window', big.actor()?.opacity === 255,
        big.actor()?.opacity);
    check('shown overlay takes input again', anyReactive(big.actor()));
    check('top bar under the full-screen window',
        global.window_group.get_children().indexOf(bar.actor()) <
        global.window_group.get_children().indexOf(normal.get_compositor_private()));
    await screenshot('overlay-over-fullscreen');
    normal.unmake_fullscreen();
    big.kill();
    await sleep(400);

    // 11. Popups parented to a layer surface (get_popup).
    const withPopup = new Client(['--layer', 'top', '--anchor', 'bl', '--size', '200x60',
        '--popup', '--keyboard', 'on_demand']);
    check('popup configured', await withPopup.waitFor('popup-configure'), withPopup.lines().join('|'));
    await sleep(300);
    const popupWindow = global.display.list_all_windows().find(w =>
        w.get_window_type() === Meta.WindowType.DROPDOWN_MENU && w.get_pid() === withPopup.pid);
    check('popup is a menu window of the layer surface',
        popupWindow?.get_transient_for() === withPopup.window());
    await screenshot('popup');
    withPopup.kill();

    // 12. Two overlays of one app count together for the limit.
    const half1 = new Client(['--layer', 'top', '--anchor', 'tl', '--size', '960x480',
        '--set-layer-after-ms', 'overlay:2600']);
    const half2 = new Client(['--layer', 'top', '--anchor', 'br', '--size', '960x480',
        '--set-layer-after-ms', 'overlay:2600']);
    await half2.waitFor('set-layer', 6000);
    await sleep(600);
    check('two 22% overlays of one app fade together', half1.actor()?.opacity === 89 &&
        half2.actor()?.opacity === 89, `${half1.actor()?.opacity} ${half2.actor()?.opacity}`);
    half1.kill();
    await sleep(600);
    check('one 22% overlay alone is not faded', half2.actor()?.opacity === 255, half2.actor()?.opacity);
    half2.kill();

    // 14. Protocol errors.
    const bad = new Client(['--layer', 'top', '--anchor', 't', '--size', '0x30']);
    check('width 0 without both side anchors is an error', await bad.waitFor('error'),
        bad.lines().join('|'));

    // 15. Panel without PANEL: held, not shown; granting maps it with no
    //     retry from the app.
    compositor.set_layer_shell_grants(APP, 0, Cap.PANEL);
    const nopanel = new Client(['--layer', 'top', '--anchor', 't', '--size', '100x30']);
    await nopanel.waitFor('configure');
    await sleep(500);
    const held = compositor.get_layer_shell_surfaces().deepUnpack()
        .filter(s => s[1] === nopanel.name);
    check('panel without the capability is held', !nopanel.window() && held.length === 1 && held[0][5],
        JSON.stringify(held));
    compositor.set_layer_shell_grants(APP, Cap.PANEL, 0);
    check('granting maps the held panel', !!await nopanel.waitWindow(), nopanel.lines().join('|'));

    // 16. Taking a grant away clamps again: overlay goes on top.
    compositor.set_layer_shell_grants(APP, Cap.OVERLAY, 0);
    const overlay2 = new Client(['--layer', 'overlay', '--anchor', 'tr', '--size', '100x100']);
    await overlay2.waitWindow();
    compositor.set_layer_shell_grants(APP, 0, Cap.OVERLAY);
    await sleep(300);
    check('revoked overlay clamped onto the top layer',
        overlay2.actor()?.get_parent() === global.window_group, overlay2.lines().join('|'));
    compositor.set_layer_shell_grants(APP, 0, 0);

    // 17. Stop: the app's overlays go for this session; its grants stay.
    compositor.set_layer_shell_grants(APP, Cap.OVERLAY, 0);
    const stopped = new Client(['--layer', 'overlay', '--anchor', 'tr', '--size', '100x100']);
    await stopped.waitWindow();
    compositor.stop_layer_overlays(APP);
    check('stop closes the overlay', await stopped.waitFor('closed'), stopped.lines().join('|'));
    const again = new Client(['--layer', 'overlay', '--anchor', 'tr', '--size', '100x100']);
    check('a stopped app gets no new overlay this session', await again.waitFor('closed'),
        again.lines().join('|'));
    const stillTop = new Client(['--layer', 'top', '--anchor', 't', '--size', '100x30']);
    check('stop leaves the other grants', !!await stillTop.waitWindow());
    stillTop.kill();

    compositor.set_layer_shell_grants(APP, 0, 0);

    bar.kill();
    bg.kill();
    await sleep(500);
    check('work area restored', JSON.stringify(workArea()) === JSON.stringify(base),
        JSON.stringify(workArea()));
}

run().catch(e => check('driver', false, `${e}\n${e.stack}`)).finally(() => {
    GLib.file_set_contents(`${out}/result.json`, JSON.stringify({results, shots}, null, 1));
    global.context.terminate();
});
