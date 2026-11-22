// SPDX-License-Identifier: GPL-2.0-or-later
// Layer-shell grants (0393, lumaLayerShellModel.js): how permission-store
// rows become Mutter's capability masks, that an offer is made once per app
// and capability, that switching one capability keeps the others and the
// "used" marks, and which apps change when the table does.
// Run: gjs -m layer-shell-policy.js js/ui/lumaLayerShellModel.js
const gjs = typeof globalThis.ARGV !== 'undefined';
const args = gjs ? globalThis.ARGV : process.argv.slice(2);
const print = gjs ? globalThis.print : console.log;
const path = args[0].startsWith('/') ? args[0]
    : `${gjs ? (await import('gi://GLib')).default.get_current_dir() : process.cwd()}/${args[0]}`;
const M = await import(`file://${path}`);

let passed = 0;
function check(value, message) {
    if (!value)
        throw new Error(`FAIL: ${message}`);
    passed++;
}
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);

// The bits are Meta.LayerShellCapabilities.
check(M.Capability.BACKGROUND === 1 && M.Capability.PANEL === 2 &&
    M.Capability.OVERLAY === 4 && M.Capability.KEYBOARD === 8, 'capability bits');
check(M.TABLE === 'luma' && M.ID === 'display-over-apps', 'store location');

// Rows to masks.
check(eq(M.grantsFor(undefined), {granted: 0, refused: 0}), 'no row: defaults');
check(eq(M.grantsFor(['overlay', 'used-overlay']), {granted: 4, refused: 0}), 'overlay granted');
check(eq(M.grantsFor(['-panel', '-background']), {granted: 0, refused: 3}), 'host defaults refused');
check(eq(M.grantsFor(['keyboard', '-keyboard']), {granted: 8, refused: 0}), 'a grant wins over a stale refusal');

// Switching keeps the rest.
const row = ['panel', 'used-panel', '-overlay'];
check(eq(M.decide(row, M.Capability.OVERLAY, true), ['panel', 'used-panel', 'overlay']), 'allow overlay');
check(eq(M.decide(row, M.Capability.PANEL, false), ['used-panel', '-overlay', '-panel']), 'refuse panel');
check(eq(M.decide(undefined, M.Capability.KEYBOARD, false), ['-keyboard']), 'refuse from nothing');

// Used and asked, with times.
check(eq(M.markUsed(['overlay'], M.Capability.OVERLAY, 100), ['overlay', 'used-overlay@100']), 'mark used');
check(eq(M.markUsed(['overlay', 'used-overlay@100'], M.Capability.OVERLAY, 200), ['overlay', 'used-overlay@200']), 'used again: newest time');
check(M.wasUsed(['used-panel@5'], M.Capability.PANEL) && !M.wasUsed(['panel'], M.Capability.PANEL), 'wasUsed');
check(M.lastUsed(['used-panel@5'], M.Capability.PANEL) === 5, 'lastUsed');

// One offer per app and capability: asked once, Not now refuses.
check(M.shouldOffer(undefined, M.Capability.OVERLAY), 'offer when undecided');
const asked = M.markAsked(undefined, M.Capability.OVERLAY, 50);
check(!M.shouldOffer(asked, M.Capability.OVERLAY), 'not twice, even unanswered');
check(M.askedAt(asked, M.Capability.OVERLAY) === 50, 'askedAt');
check(M.shouldOffer(asked, M.Capability.KEYBOARD), 'another capability is still offered');
const notNow = M.decide(asked, M.Capability.OVERLAY, false);
check(eq(M.grantsFor(notNow), {granted: 0, refused: 4}) && !M.shouldOffer(notNow, M.Capability.OVERLAY), 'Not now refuses');
check(eq(M.describe(['overlay', 'used-overlay@9', 'asked-keyboard@3', '-keyboard']),
    {granted: 4, refused: 8, used: 4, lastUsed: {4: 9}, asked: {8: 3}}), 'describe');

// Table changes.
check(eq(M.changes({}, {a: ['overlay']}), [['a', {granted: 4, refused: 0}]]), 'new row');
check(eq(M.changes({a: ['overlay']}, {}), [['a', {granted: 0, refused: 0}]]), 'removed row');
check(eq(M.changes({a: ['overlay']}, {a: ['overlay', 'used-overlay@3', 'asked-panel@1']}), []), 'used and asked marks change nothing');
check(eq(M.changes({b: ['panel'], a: []}, {b: ['-panel'], a: ['x']}).map(c => c[0]), ['b']), 'only real changes, sorted');

print(`layer-shell-policy: ${passed} checks passed`);
