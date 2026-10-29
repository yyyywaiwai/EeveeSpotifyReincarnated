'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../../Scripts/offline-prefetch-proof.js'), 'utf8');

function run({states = [1, 2], objc = true, exportPresent = true} = {}) {
    const output = [];
    let now = 0;
    let timer;
    let calls = 0;
    let cleared = false;
    const context = {
        ObjC: {available: objc, mainQueue: {}, schedule(_queue, callback) { callback(); }},
        Module: {getGlobalExportByName(name) {
            assert.equal(name, 'eevee_offline_prefetch_proof_once');
            if (!exportPresent) throw new Error('missing');
            return name;
        }},
        NativeFunction: function () { return () => { calls++; return states.shift(); }; },
        Date: {now: () => now},
        setInterval(callback, interval) { assert.equal(interval, 500); timer = callback; return 1; },
        clearInterval(id) { assert.equal(id, 1); cleared = true; },
        send(value) { assert.equal(typeof value, 'number'); output.push(value); },
    };
    vm.runInNewContext(source, context, {filename: 'offline-prefetch-proof.js'});
    return {
        start() { context.startProof(); },
        tick() { timer(); },
        advance(ms) { now += ms; },
        output, get calls() { return calls; }, get cleared() { return cleared; },
    };
}

{
    const test = run();
    test.start();
    test.start();
    assert.deepEqual(test.output, [1]);
    assert.equal(test.calls, 1);
    test.tick();
    assert.deepEqual(test.output, [1, 2]);
    assert.equal(test.calls, 2);
    assert.equal(test.cleared, true);
    test.tick();
    assert.equal(test.calls, 2);
}

{
    const test = run({states: [-3]});
    test.start();
    assert.deepEqual(test.output, [-3]);
    assert.equal(test.cleared, true);
}

{
    const test = run({objc: false});
    test.start();
    assert.deepEqual(test.output, [-100]);
    assert.equal(test.calls, 0);
}

{
    const test = run({exportPresent: false});
    test.start();
    assert.deepEqual(test.output, [-101]);
    assert.equal(test.calls, 0);
}

{
    const test = run({states: [1]});
    test.start();
    test.advance(360_000);
    test.tick();
    assert.deepEqual(test.output, [1, -102]);
    assert.equal(test.cleared, true);
    assert.equal(test.calls, 1);
}

console.log('OfflinePrefetchProof runner tests passed');
