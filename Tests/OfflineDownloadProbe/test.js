'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../../Scripts/probe-offline-download.js'), 'utf8');
const nullPointer = () => new Pointer(null);

class Pointer {
    constructor(value, offset = 0) {
        this.value = value;
        this.offset = offset;
    }
    isNull() { return this.value === null; }
    add(offset) { return new Pointer(this.value, this.offset + offset); }
    readPointer() {
        assert(Array.isArray(this.value), 'pointer list expected');
        assert(this.offset / 8 < this.value.length, 'out-of-capacity pointer read');
        return this.value[this.offset / 8];
    }
    readUtf8String() {
        if (this.value === INVALID_UTF8) throw new Error('invalid UTF-8');
        assert.equal(typeof this.value, 'string');
        return this.value;
    }
    writeU32(value) { this.value.u32 = value; }
    readU32() { return this.value.u32; }
}

const INVALID_UTF8 = Symbol('invalid UTF-8');
const string = value => new Pointer(value);
const method = (selector, types = 'v16@0:8') => new Pointer({selector, types});
const cls = (name, methods = [], superclass = null, imagePath = '/TARGET/SpotifyShared') =>
    new Pointer({name, methods, superclass, imagePath});

function run({classes = [], reported = classes.length, modules = []} = {}) {
    const freed = [];
    let getClassesCalls = 0;
    const functions = {
        objc_getClassList(buffer, capacity) {
            getClassesCalls++;
            if (buffer.isNull()) return classes.length;
            assert.equal(capacity, classes.length);
            buffer.value = classes.slice();
            return reported;
        },
        class_getName(pointer) { return string(pointer.value.name); },
        class_getSuperclass(pointer) {
            return pointer.value.superclass === null ? nullPointer() : cls(pointer.value.superclass);
        },
        class_getImageName(pointer) { return string(pointer.value.imagePath); },
        class_copyMethodList(pointer, count) {
            const methods = pointer.value.methods;
            count.writeU32(methods === null ? 3 : methods.length);
            return methods === null ? nullPointer() : new Pointer(methods);
        },
        method_getName(pointer) { return string(pointer.value.selector); },
        sel_getName(pointer) { return pointer; },
        method_getTypeEncoding(pointer) { return string(pointer.value.types); },
        free(pointer) { freed.push(pointer); },
    };
    const context = {
        Module: {getGlobalExportByName(name) {
            assert(Object.hasOwn(functions, name), 'unexpected native API: ' + name);
            return name;
        }},
        NativeFunction: function (name) { return functions[name]; },
        Memory: {alloc(size) {
            assert(size > 0);
            return new Pointer({size});
        }},
        Process: {pointerSize: 8, id: 123, arch: 'arm64', enumerateModules: () => modules},
        ptr(value) {
            assert.equal(value, 0);
            return nullPointer();
        },
        rpc: {},
    };
    vm.runInNewContext(source, context, {filename: 'probe-offline-download.js'});
    assert.deepEqual(Object.keys(context.rpc.exports), ['inventory']);
    const result = JSON.parse(JSON.stringify(context.rpc.exports.inventory()));
    assert.equal(getClassesCalls, 2);
    return {result, freed};
}

{
    const {result, freed} = run({
        classes: [
            cls('Unrelated.OfflineMetadata', [method('private:')]),
            cls('Offline_ContentOffliningUIImpl.ContentOffliningUIHelperImplementation', [
                method('init'), method('.cxx_destruct'),
            ]),
            cls('_TtC18Download_StateImpl19DownloadManagerImpl'),
            cls('LocalFiles_CoreImpl.LocalFilesAPIService', [method('load')]),
            cls('YourLibrary_YourLibraryXImpl.YourLibraryViewController', [method('viewDidLoad')]),
            cls('SPTEsperantoPlayer', [method('playContext:options:', 'v32@0:8@16@24')], 'NSObject'),
            cls('SPTOfflineService', [method('status')]),
        ],
        modules: [
            {name: 'UIKit', path: '/System/UIKit'},
            {name: 'Spotify', path: '/TARGET/Spotify.app/Spotify'},
            {name: 'EeveeSpotify.dylib', path: '/TARGET/EeveeSpotify.dylib'},
            {name: 'SpotifyShared', path: '/TARGET/SpotifyShared'},
        ],
    });
    assert.equal(result.version, 1);
    assert.equal(result.methodScope, 'own-instance-methods');
    assert.equal(result.classes.length, 6);
    assert(!result.classes.some(entry => entry.name.startsWith('Unrelated')));
    assert.deepEqual(result.classes.find(entry => entry.name === 'SPTEsperantoPlayer').methods, [
        {selector: 'playContext:options:', typeEncoding: 'v32@0:8@16@24'},
    ]);
    assert.equal(result.classes.find(entry => entry.name === 'SPTEsperantoPlayer').superclass, 'NSObject');
    assert.equal(result.classes.find(entry => entry.name === 'SPTEsperantoPlayer').imagePath, '/TARGET/SpotifyShared');
    assert.deepEqual(result.classes.find(entry => entry.name.startsWith('Offline_')).methods.map(entry => entry.selector), [
        '.cxx_destruct', 'init',
    ]);
    assert.equal(result.images.length, 3);
    assert(result.images.every(entry => /eevee|spotify/i.test(entry.name)));
    assert.equal(freed.length, 6);
    assert(Object.values(result.skipped).every(value => value === 0));
}

{
    const {result, freed} = run({classes: [
        nullPointer(),
        cls(INVALID_UTF8),
        cls(null),
        cls('Download_StateImpl.DownloadManagerImpl', null, INVALID_UTF8, INVALID_UTF8),
        cls('SPTEsperantoPlayer', [
            nullPointer(),
            method(INVALID_UTF8),
            method(null),
            method('invalidTypes', INVALID_UTF8),
            method('nullTypes', null),
            method('playContext:options:', 'v32@0:8@16@24'),
        ]),
    ]});
    assert.equal(result.classes.length, 2, 'malformed metadata must not abort the snapshot');
    assert.deepEqual(result.skipped, {
        nullClasses: 1, classNames: 2, superclassNames: 1, imageNames: 1, nullMethodLists: 1,
        nullMethods: 1, selectors: 2, typeEncodings: 2,
    });
    assert.equal(result.classes.find(entry => entry.name === 'SPTEsperantoPlayer').methods.length, 1);
    assert.equal(freed.length, 1, 'a null method list must not be read or freed');
}

{
    const {result} = run({classes: [cls('SPTEsperantoPlayer')], reported: 3});
    assert.deepEqual(result.classCount, {capacity: 1, reported: 3, scanned: 1, truncated: true});
    assert.equal(result.classes.length, 1);
}

{
    const {result} = run({classes: [cls('SPTEsperantoPlayer'), cls('SPTOfflineService')], reported: 1});
    assert.deepEqual(result.classCount, {capacity: 2, reported: 1, scanned: 1, truncated: false});
    assert.equal(result.classes.length, 1);
}

assert.deepEqual(run().result.classCount, {capacity: 0, reported: 0, scanned: 0, truncated: false});
console.log('Offline download metadata probe tests passed');
