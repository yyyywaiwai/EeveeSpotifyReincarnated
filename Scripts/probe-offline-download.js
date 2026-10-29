'use strict';

// Metadata only: no ObjC bridge, application method calls, or request/track data.
const playerClasses = new Set([
    'SPTEsperantoPlayer',
    'SPTPlayerServiceImplementation',
    'SPTStatefulPlayerImplementation',
    'SPTPlayerTrack',
    'SPTPlayerState',
    '_TtC17Player_CommonImpl30SPTPlayerServiceImplementation',
]);

function relevantClass(name) {
    return playerClasses.has(name) ||
        /^(?:_TtC\d+)?(?:Offline_|Download_|LocalFiles_|YourLibrary_)/.test(name) ||
        /^SPT(?:Offline|LocalFiles)/.test(name);
}

function native(name, result, args) {
    return new NativeFunction(Module.getGlobalExportByName(name), result, args);
}

function inventory() {
    const getClasses = native('objc_getClassList', 'int', ['pointer', 'int']);
    const className = native('class_getName', 'pointer', ['pointer']);
    const superclass = native('class_getSuperclass', 'pointer', ['pointer']);
    const classImage = native('class_getImageName', 'pointer', ['pointer']);
    const copyMethods = native('class_copyMethodList', 'pointer', ['pointer', 'pointer']);
    const methodName = native('method_getName', 'pointer', ['pointer']);
    const selectorName = native('sel_getName', 'pointer', ['pointer']);
    const methodTypes = native('method_getTypeEncoding', 'pointer', ['pointer']);
    const free = native('free', 'void', ['pointer']);
    const skipped = {
        nullClasses: 0,
        classNames: 0,
        superclassNames: 0,
        imageNames: 0,
        nullMethodLists: 0,
        nullMethods: 0,
        selectors: 0,
        typeEncodings: 0,
    };

    function string(pointer, category) {
        try {
            if (!pointer.isNull()) {
                const value = pointer.readUtf8String();
                if (value) return value;
            }
        } catch (_) {
            // One malformed runtime string must not discard the snapshot.
        }
        skipped[category]++;
        return null;
    }

    const capacity = Math.max(0, getClasses(ptr(0), 0));
    const buffer = Memory.alloc(Math.max(1, capacity) * Process.pointerSize);
    const reported = Math.max(0, getClasses(buffer, capacity));
    const scanned = Math.min(capacity, reported);
    const classes = [];
    const count = Memory.alloc(4);

    for (let i = 0; i < scanned; i++) {
        const cls = buffer.add(i * Process.pointerSize).readPointer();
        if (cls.isNull()) {
            skipped.nullClasses++;
            continue;
        }
        const name = string(className(cls), 'classNames');
        if (name === null || !relevantClass(name)) continue;
        const parent = superclass(cls);
        const superclassName = parent.isNull() ? null : string(className(parent), 'superclassNames');
        const imagePath = string(classImage(cls), 'imageNames');

        count.writeU32(0);
        const list = copyMethods(cls, count);
        const methods = [];
        if (list.isNull()) {
            skipped.nullMethodLists++;
        } else {
            try {
                for (let j = 0; j < count.readU32(); j++) {
                    const method = list.add(j * Process.pointerSize).readPointer();
                    if (method.isNull()) {
                        skipped.nullMethods++;
                        continue;
                    }
                    const sel = methodName(method);
                    const selector = string(sel.isNull() ? sel : selectorName(sel), 'selectors');
                    if (selector === null) continue;
                    const typeEncoding = string(methodTypes(method), 'typeEncodings');
                    if (typeEncoding !== null) methods.push({selector, typeEncoding});
                }
            } finally {
                free(list);
            }
        }
        methods.sort((a, b) => a.selector.localeCompare(b.selector));
        classes.push({name, superclass: superclassName, imagePath, methods});
    }

    classes.sort((a, b) => a.name.localeCompare(b.name));
    const images = Process.enumerateModules()
        .filter(module => /eevee|spotify/i.test(module.name))
        .map(module => ({name: module.name, path: module.path}))
        .sort((a, b) => a.name.localeCompare(b.name));
    return {
        version: 1,
        process: {id: Process.id, arch: Process.arch},
        classCount: {capacity, reported, scanned, truncated: reported > capacity},
        methodScope: 'own-instance-methods',
        skipped,
        images,
        classes,
    };
}

rpc.exports = {inventory};
