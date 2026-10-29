'use strict';

// Invoke startProof() once after Spotify is foreground and the fixed first track is paused.
let proofStarted = false;

function startProof() {
    if (proofStarted) return;
    proofStarted = true;

    if (!ObjC.available) { send(-100); return; }
    let proof;
    try {
        proof = new NativeFunction(Module.getGlobalExportByName('eevee_offline_prefetch_proof_once'), 'int', []);
    } catch (_) {
        send(-101);
        return;
    }

    let lastState;
    let pending = false;
    let stopped = false;
    const deadline = Date.now() + 360_000;
    const timer = setInterval(poll, 500);

    function stop() {
        stopped = true;
        clearInterval(timer);
    }

    function poll() {
        if (stopped) return;
        if (Date.now() >= deadline) { send(-102); stop(); return; }
        if (pending) return;
        pending = true;
        ObjC.schedule(ObjC.mainQueue, () => {
            try {
                if (stopped) return;
                const state = proof();
                if (state !== lastState) {
                    send(state);
                    lastState = state;
                }
                if (state !== 1) stop();
            } catch (_) {
                send(-103);
                stop();
            } finally {
                pending = false;
            }
        });
    }

    poll();
}
