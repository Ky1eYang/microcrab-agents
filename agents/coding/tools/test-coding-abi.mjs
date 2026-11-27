// An independent wire witness, not a second Zig layout implementation. Typed
// import mocks write explicit WIT offsets and check the flat Wasm arguments.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8', { fatal: true });
let memory;
let realloc;
let communicationError = false;
let dropCount = 0;
let borrowDropCount = 0;
let pendingBorrow = false;
let markCount = 0;
let mutationCount = 0;
let factsCount = 0;
const dynamic = 0x100000000n;
const buffer = 73;
const processId = dynamic + 8n;
const path = 'é/λ.txt';
const text = 'current é\u0000';
const imports = {};
const view = () => new DataView(memory.buffer);
const bytes = (at, len) => new Uint8Array(memory.buffer, at, len);
const get8 = at => view().getUint8(at);
const get32 = at => view().getUint32(at, true);
const get64 = at => view().getBigUint64(at, true);
const put8 = (at, value) => view().setUint8(at, value);
const put32 = (at, value) => view().setUint32(at, value, true);
const put64 = (at, value) => view().setBigUint64(at, value, true);
const stringAt = (at, len) => decoder.decode(bytes(at, len));
const getText = at => stringAt(get32(at), get32(at + 4));

function alloc(input, alignment = 1) {
    const data = typeof input === 'string' ? encoder.encode(input) : input;
    if (!data.length) return [0, 0];
    const at = realloc(0, 0, alignment, data.length);
    bytes(at, data.length).set(data);
    return [at, data.length];
}
function writeList(at, data) {
    const [ptr, len] = alloc(data);
    put32(at, ptr);
    put32(at + 4, len);
}
function listArea(at, stride, count, alignment) {
    const start = realloc(0, 0, alignment, stride * count);
    bytes(start, stride * count).fill(0);
    put32(at, start);
    put32(at + 4, count);
    return start;
}
function response(at, size, alignment, tag = 0) {
    assert.equal(at % alignment, 0);
    // Poison inactive payload/padding to catch relying on their values.
    bytes(at, size).fill(0xff);
    put8(at, tag);
    return at + alignment;
}
function mock(interfaceName, name, fn) {
    const [namespace, nameOfInterface] = interfaceName.includes('/') ? interfaceName.split('/') : ['host', interfaceName];
    const version = interfaceName === 'session/session' ? '0.4.0' : { agent: '0.9.0', host: '0.1.0', session: '0.2.0' }[namespace];
    const key = `microcrab:${namespace}/${nameOfInterface}@${version}`;
    (imports[key] ??= {})[name] = fn;
}
function okVoid(at) {
    response(at, 28, 4);
}
function opError(at, tag, message) {
    const out = response(at, 16, 4, 1);
    put8(out, tag);
    writeList(out + 4, message);
}
function checkHandle(id, tag, pid) {
    assert.deepEqual([id, tag, pid], [processId, 0, 0]);
}

mock('agent/host-info', 'host-info', at => {
    if (communicationError) opError(at, 1, 'unavailable Ω');
    else writeList(response(at, 16, 4), '{}');
});
const execution = 'agent/execution';
mock(execution, 'create', (ptr, count, at) => {
    assert.equal(count, 2);
    assert.equal(ptr % 4, 0);
    assert.equal(getText(ptr), 'stdout');
    assert.deepEqual([get8(ptr + 8), get32(ptr + 12), get32(ptr + 16)], [0, 0, 0]);
    assert.equal(getText(ptr + 20), 'fixture-bytes');
    assert.equal(get8(ptr + 28), 1);
    assert.equal(getText(ptr + 32), 'image/png');
    put32(response(at, 28, 4), buffer);
});
mock(execution, 'append', (id, tag, channel, channelLen, content, contentLen, at) => {
    assert.equal(id, buffer);
    if (tag) {
        assert.equal(stringAt(channel, channelLen), 'stdout');
        assert.equal(stringAt(content, contentLen), 'stdout ü');
    } else assert.deepEqual([channel, channelLen, content, contentLen], [0, 0, 0, 0]);
    okVoid(at);
});
mock(execution, 'finish', (id, tag, kind, code, codeLen, msg, msgLen, retryable, at) => {
    assert.equal(id, buffer);
    if (tag) {
        assert.deepEqual([kind, retryable], [0, 1]);
        assert.equal(stringAt(code, codeLen), 'probe-code');
        assert.equal(stringAt(msg, msgLen), 'probe-message');
    } else assert.deepEqual([kind, code, codeLen, msg, msgLen, retryable], [0, 0, 0, 0, 0, 0]);
    okVoid(at);
});
mock(execution, 'attach-process', (id, proc, tag, pid, source, at) => {
    assert.deepEqual([id, proc, tag, pid, source], [buffer, dynamic + 7n, 1, 42, 0]);
    okVoid(at);
});
mock(execution, 'retain-process', (id, proc, tag, pid, source, at) => {
    assert.deepEqual([id, proc, tag, pid, source], [buffer, processId, 0, 0, 1]);
    okVoid(at);
});
mock(execution, 'attach-guest', (id, ptr, len, at) => {
    assert.equal(id, buffer);
    assert.equal(stringAt(ptr, len), 'state');
    okVoid(at);
});
mock(execution, 'mark-truncated', (id, at) => {
    assert.equal(id, buffer);
    markCount++;
    okVoid(at);
});
mock(execution, '[resource-drop]buffer', id => {
    assert.equal(id, buffer);
    if (pendingBorrow) {
        pendingBorrow = false;
        borrowDropCount++;
    } else dropCount++;
});
mock('session/file-versions', 'read', (ptr, len, offset, lines, max, at) => {
    assert.equal(stringAt(ptr, len), path);
    assert.deepEqual([offset, lines, max], [dynamic + 2n, 3n, 4n]);
    const out = response(at, 64, 8);
    writeList(out, text);
    put64(out + 8, 3n);
    put8(out + 16, 1);
    put64(out + 24, dynamic + 3n);
    put8(out + 32, 1);
    writeList(out + 36, 'v1');
    writeList(out + 48, 'fv_0123456789abcdef');
});
mock('session/file-versions', 'write', (ptr, len, content, contentLen, tag, pre, preLen, at) => {
    assert.equal(stringAt(ptr, len), path);
    assert.equal(stringAt(content, contentLen), text);
    assert.equal(tag, 1);
    assert.equal(stringAt(pre, preLen), 'v1');
    const out = response(at, 24, 8);
    writeList(out, 'v2');
    put64(out + 8, dynamic + 4n);
});
mock('session/file-versions', 'preflight', (ptr, len, at) => {
    assert.equal(len, 3);
    assert.equal(get8(ptr), 0);
    assert.equal(getText(ptr + 4), path);
    assert.equal(getText(ptr + 12), '');
    assert.equal(get8(ptr + 20), 0);
    assert.equal(get8(ptr + 36), 1);
    assert.equal(getText(ptr + 40), path);
    assert.equal(getText(ptr + 48), 'v2');
    assert.equal(get8(ptr + 72), 2);
    assert.equal(getText(ptr + 76), path);
    assert.equal(getText(ptr + 84), 'dest');
    assert.equal(getText(ptr + 92), 'v3');
    assert.equal(getText(ptr + 100), 'moved');
    const list = listArea(response(at, 16, 4), 36, 3, 4);
    put8(list, 0);
    writeList(list + 4, path);
    writeList(list + 12, 'from-host');
    put8(list + 20, 1);
    writeList(list + 24, 'v-host');
    put8(list + 36, 1);
    writeList(list + 40, path);
    writeList(list + 48, 'v2');
    put8(list + 72, 2);
    for (const [index, value] of [path, 'dest', 'v3', 'moved'].entries()) {
        writeList(list + 76 + 8 * index, value);
    }
});
mock('session/file-versions', 'mutate', (tag, p0, n0, p1, n1, p2, p3, p4, n4, at) => {
    mutationCount++;
    assert.equal(stringAt(p0, n0), path);
    if (tag === 0) {
        assert.equal(stringAt(p1, n1), 'from-host');
        assert.equal(p2, 1);
        assert.equal(stringAt(p3, p4), 'v-host');
        assert.equal(n4, 0);
    } else if (tag === 1) {
        assert.equal(stringAt(p1, n1), 'v2');
        assert.deepEqual([p2, p3, p4, n4], [0, 0, 0, 0]);
    } else {
        assert.equal(tag, 2);
        assert.equal(stringAt(p1, n1), 'dest');
        assert.equal(stringAt(p2, p3), 'v3');
        assert.equal(stringAt(p4, n4), 'moved');
    }
    const out = response(at, 48, 8);
    put8(out, 0);
    put64(out + 16, 17n);
    put8(out + 24, 0);
    put8(out + 25, 1);
    put8(out + 28, 1);
    writeList(out + 32, 'partial');
});
mock('cache-points', 'capture', (ptr, len, max, at) => {
    assert.equal(stringAt(ptr, len), path);
    assert.equal(max, 999n);
    opError(at, 3, 'cache conflict');
});
mock('glob-ignore', 'glob-from-state', (root, rootLen, pattern, patternLen, hidden, ignored, directories, max, at) => {
    assert.equal(stringAt(root, rootLen), path);
    assert.equal(stringAt(pattern, patternLen), '*');
    if (max === 4096n) {
        assert.deepEqual([hidden, ignored, directories], [0, 0, 0]);
        const out = response(at, 16, 4);
        const list = listArea(out, 12, 4096, 4);
        for (let i = 0; i < 4096; i++) writeList(list + 12 * i, 'entry.txt');
        put8(out + 8, 0);
        return;
    }
    assert.deepEqual([hidden, ignored, directories, max], [1, 0, 1, dynamic + 5n]);
    const out = response(at, 16, 4);
    const list = listArea(out, 12, 2, 4);
    writeList(list, 'first');
    put8(list + 8, 2);
    writeList(list + 12, 'second');
    put8(list + 20, 0);
    put8(out + 8, 1);
});
mock('grep', 'grep', (root, rootLen, pattern, patternLen, tag, glob, globLen, cs, literal, max, maxBytes, at) => {
    assert.equal(stringAt(root, rootLen), path);
    assert.equal(stringAt(pattern, patternLen), 'find');
    assert.equal(stringAt(glob, globLen), '*.zig');
    assert.deepEqual([tag, cs, literal, max, maxBytes], [1, 0, 1, 10n, 11n]);
    const out = response(at, 16, 4);
    const list = listArea(out, 24, 1, 8);
    writeList(list, path);
    put64(list + 8, dynamic + 6n);
    writeList(list + 16, 'found');
    put8(out + 8, 0);
});
mock('shell', 'launch', (command, len, tag, cwd, cwdLen, at) => {
    assert.equal(stringAt(command, len), 'test');
    assert.equal(tag, 1);
    assert.equal(stringAt(cwd, cwdLen), path);
    const out = response(at, 24, 8);
    put64(out, processId);
    put8(out + 8, 0);
});
mock('process', 'status', (id, tag, pid, at) => {
    checkHandle(id, tag, pid);
    const out = response(at, 40, 8);
    put8(out, 1);
    put32(out + 4, 42);
    put8(out + 8, 1);
    put8(out + 12, 1);
    view().setInt32(out + 16, -3, true);
    put8(out + 20, 1);
    put8(out + 21, 1);
    view().setFloat64(out + 24, 1.25, true);
});
mock('process', 'wait-for-state', (id, tag, pid, wait, at) => {
    checkHandle(id, tag, pid);
    assert.equal(wait, 50n);
    const out = response(at, 40, 8);
    put8(out, 0);
    put8(out + 8, 0);
    view().setFloat64(out + 24, 0.5, true);
});
mock('shell', 'read', (id, tag, pid, max, at) => {
    checkHandle(id, tag, pid);
    assert.equal(max, 100n);
    const out = response(at, 24, 4);
    writeList(out, 'out');
    writeList(out + 8, 'err');
    put8(out + 16, 1);
});
mock('shell', 'drain', (id, tag, pid, max, at) => {
    checkHandle(id, tag, pid);
    assert.equal(max, 101n);
    const out = response(at, 24, 4);
    writeList(out, '');
    writeList(out + 8, '');
    put8(out + 16, 0);
});
mock('shell', 'write', (id, tag, pid, data, len, eof, at) => {
    checkHandle(id, tag, pid);
    assert.equal(stringAt(data, len), 'write');
    assert.equal(eof, 1);
    response(at, 16, 4);
});
mock('process', 'kill-tree', (id, tag, pid, force, at) => {
    checkHandle(id, tag, pid);
    assert.equal(force, 1);
    const out = response(at, 16, 4, 1);
    put8(out, 1);
    put8(out + 1, 1);
    writeList(out + 4, 'deny');
});
mock('process', 'release', (id, tag, pid, at) => {
    checkHandle(id, tag, pid);
    response(at, 16, 4);
});

const session = 'session/session';
mock(session, 'eval', (scriptPtr, scriptLen, argsTag, argsPtr, argsLen, at) => {
    const script = stringAt(scriptPtr, scriptLen);
    if (script === 'vars::call_facts()') {
        assert.equal(argsTag, 0);
        const phase = factsCount++ % 3;
        if (phase === 2) {
            opError(at, 1, 'not admitted');
            return;
        }
        const modeJson = phase === 0 ? '"plan"' : 'null';
        const tsJson = phase === 0 ? 0xfedcba9876543210n.toString() : '1';
        writeList(
            response(at, 16, 4),
            `{"session_id":"session-exact-🦀","admitted_mode":${modeJson},"observed_at_unix_ms":${tsJson}}`,
        );
        return;
    }
    if (script === 'vars::get("null-value")') {
        assert.equal(argsTag, 0);
        writeList(response(at, 16, 4), 'null');
        return;
    }
    if (script === 'vars::get("missing")') {
        assert.equal(argsTag, 0);
        opError(at, 0, 'not found');
        return;
    }
    if (script === 'args.value') {
        assert.equal(argsTag, 1);
        const parsed = JSON.parse(stringAt(argsPtr, argsLen));
        writeList(response(at, 16, 4), JSON.stringify(parsed.value));
        return;
    }
    if (script === 'vars::set("blocked", true)') {
        assert.equal(argsTag, 1);
        assert.deepEqual(JSON.parse(stringAt(argsPtr, argsLen)), { blocked: true });
        opError(at, 2, 'fixture rejection');
        return;
    }
    assert.fail(`unexpected eval probe script: ${script}`);
});

const module = new WebAssembly.Module(readFileSync(process.argv[2]));
assert.equal(WebAssembly.Module.imports(module).length,
    Object.values(imports).reduce((sum, namespace) => sum + Object.keys(namespace).length, 0));
const exports = new WebAssembly.Instance(module, imports).exports;
({ memory, cabi_realloc: realloc } = exports);

function run() {
    communicationError = false;
    let result = exports.init();
    assert.equal(get8(result), 0);
    exports.cabi_post_init(result);
    communicationError = true;
    result = exports.init();
    assert.equal(get8(result), 1);
    assert.equal(getText(result + 4), 'unavailable');
    assert.equal(getText(result + 12), 'unavailable Ω');
    exports.cabi_post_init(result);

    for (const [value, tag] of [['multibyte 你', 0], ['invalid', 1], ['', 0]]) {
        result = exports.describe(...alloc(value));
        assert.equal(get8(result), tag);
        assert.equal(getText(result + 4), value);
        exports.cabi_post_describe(result);
    }

    result = exports.invoke(...alloc('hello'), ...alloc('final'), ...alloc('binary\u0000'));
    assert.deepEqual([get8(result), get8(result + 4)], [0, 0]);
    assert.equal(getText(result + 8), 'hello');
    assert.equal(get8(result + 16), 1);
    assert.equal(get8(result + 20), 1);
    assert.equal(getText(result + 24), 'probe');
    assert.equal(getText(result + 32), 'final');
    assert.equal(get8(result + 40), 1);
    assert.equal(get32(result + 48), 2);
    const attachments = get32(result + 44);
    assert.equal(getText(attachments), 'image/png');
    assert.equal(getText(attachments + 8), 'binary\u0000');
    assert.equal(getText(attachments + 16), 'image/gif');
    assert.deepEqual([...bytes(get32(attachments + 24), get32(attachments + 28))], [0, 255]);
    exports.cabi_post_invoke(result);

    result = exports.invoke(...alloc('stdout ü'), ...alloc('buffer'), ...alloc('drop'));
    assert.equal(get8(result), 1);
    assert.equal(getText(result + 8), 'drop');
    exports.cabi_post_invoke(result);

    result = exports.invoke(...alloc('stdout ü'), ...alloc('buffer'), ...alloc('state'));
    assert.deepEqual([get8(result), get8(result + 4)], [0, 1]);
    assert.equal(get32(result + 8), buffer);
    assert.equal(get8(result + 12), 1);
    exports.cabi_post_invoke(result);

    pendingBorrow = true;
    result = exports.drive(buffer, ...alloc(Uint8Array.of(0xff, 0, 0x80)), 0);
    assert.equal(pendingBorrow, false, 'borrow removed before returning success');
    assert.equal(get8(result), 0);
    assert.deepEqual([...bytes(get32(result + 8), get32(result + 12))], [255, 0, 128]);
    assert.equal(get64(result + 16), dynamic + 1n);
    assert.equal(get8(result + 24), 1);
    exports.cabi_post_drive(result);

    pendingBorrow = true;
    result = exports.drive(buffer, ...alloc('never retained'), 1);
    assert.equal(pendingBorrow, false, 'borrow removed before returning typed failure');
    assert.equal(get8(result), 1);
    assert.equal(get8(result + 8), 2);
    assert.equal(getText(result + 12), 'cancelled');
    exports.cabi_post_drive(result);

    result = exports.invoke(...alloc(''), ...alloc('host'), ...alloc(path));
    assert.deepEqual([get8(result), get8(result + 4)], [0, 0]);
    assert.equal(getText(result + 8), text);
    exports.cabi_post_invoke(result);

    result = exports.invoke(...alloc(''), ...alloc('session'), ...alloc(''));
    assert.deepEqual([get8(result), get8(result + 4)], [0, 0]);
    assert.equal(getText(result + 8), 'session-exact-🦀');
    exports.cabi_post_invoke(result);
}

// Stabilized linear memory under repeated all-branch calls witnesses reclamation
// of inputs, nested return values, Host-owned lift allocations, and scratch.
run();
const memoryHighWater = memory.buffer.byteLength;
for (let i = 0; i < 127; i++) run();
assert.equal(memory.buffer.byteLength, memoryHighWater);
assert.equal(dropCount, 128, 'only untransferred owners are dropped by the guest');
assert.equal(borrowDropCount, 256, 'each drive closes only its scoped borrow entry');
assert.equal(markCount, 128, 'each non-cancelled drive uses its borrowed resource once');
assert.equal(mutationCount, 3 * 128);
assert.equal(factsCount, 3 * 128, 'each session probe exercises both mode options and a typed error');

function runBulk() {
    const result = exports.invoke(...alloc(''), ...alloc('bulk'), ...alloc(path));
    assert.deepEqual([get8(result), get8(result + 4)], [0, 0]);
    assert.equal(getText(result + 8), 'entry.txt');
    exports.cabi_post_invoke(result);
}
runBulk();
const bulkMemoryHighWater = memory.buffer.byteLength;
// Even the maximum-sized Coding glob must fit within Core's 64 MiB default.
assert.ok(bulkMemoryHighWater < 64 * 1024 * 1024);
for (let i = 0; i < 8; i++) runBulk();
assert.equal(memory.buffer.byteLength, bulkMemoryHighWater);
console.log('Coding ABI: 128 rounds including typed Session imports, and 4096-entry list lifting/reclamation passed.');

// Exercise the production guest, not just the transport fixture. A fallback
// to legacy glob would change the import set or hit an unexpected operation.
const guest = new WebAssembly.Module(readFileSync(process.argv[3]));
const guestImports = {};
const ignore = 'microcrab:host/glob-ignore@0.1.0';
const sessionNs = 'microcrab:session/session@0.4.0';
const hostInfo = 'microcrab:agent/host-info@0.9.0';
const agentExecution = 'microcrab:agent/execution@0.9.0';
for (const { module: namespace, name } of WebAssembly.Module.imports(guest)) {
    assert.notEqual(namespace, 'microcrab:host/glob@0.1.0');
    assert.notEqual(namespace, 'microcrab:host/text-read@0.1.0');
    assert.notEqual(namespace, 'microcrab:host/text-write@0.1.0');
    assert.notEqual(namespace, 'microcrab:host/file-mutation@0.1.0');
    assert.notEqual(namespace, 'microcrab:session/variables@0.2.0');
    assert.notEqual(namespace, 'microcrab:session/references@0.3.0');
    (guestImports[namespace] ??= {})[name] = () => assert.fail(`unexpected production import ${namespace}/${name}`);
}
const hostJson = JSON.stringify({ os_family: 'unix', os: 'linux', arch: 'x86_64', shell: 'bash',
    path_separator: '/', newline: '\n', capabilities: ['glob'] });
let snapshotReply;
let changeRejected = false;
let published;
let mountedDocs;
let snapshotCalls = 0;
let initDocGlobs = 0;
let stateGlobCalls = 0;
let dropCalls = 0;
assert.deepEqual(Object.keys(guestImports[ignore]).sort(), ['glob-ignored-paths', 'glob-with-ignored-paths']);
assert.deepEqual(Object.keys(guestImports[sessionNs]).sort(), ['eval']);
Object.assign(guestImports[ignore], {
    'glob-ignored-paths'(at) {
        snapshotCalls++;
        if (!Array.isArray(snapshotReply)) return opError(at, snapshotReply, 'private path /workspace/test');
        const out = response(at, 16, 4);
        if (snapshotReply.length === 0) {
            put32(out, 0);
            put32(out + 4, 0);
        } else {
            const list = listArea(out, 8, snapshotReply.length, 4);
            snapshotReply.forEach((path, i) => writeList(list + 8 * i, path));
        }
    },
    'glob-with-ignored-paths'(root, rootLen, pattern, patternLen, hidden, ignored, directories, max, paths, count, at) {
        const patternStr = stringAt(pattern, patternLen);
        if (patternStr === '**/AGENTS.md') {
            initDocGlobs++;
            assert.equal(stringAt(root, rootLen), '.');
            assert.deepEqual([hidden, ignored, directories, max], [0, 0, 0, 256n]);
            const passed = Array.from({ length: count }, (_, i) => getText(paths + 8 * i));
            assert.deepEqual(passed, snapshotReply);
            const out = response(at, 32, 4);
            const found = count > 0
                ? [
                    { path: 'nested/AGENTS.md', kind: 0 },
                    { path: 'dir/AGENTS.md', kind: 1 },
                    { path: 'AGENTS.md', kind: 0 },
                ]
                : [];
            if (found.length === 0) {
                put32(out, 0);
                put32(out + 4, 0);
            } else {
                const list = listArea(out, 12, found.length, 4);
                found.forEach((item, i) => {
                    writeList(list + 12 * i, item.path);
                    put8(list + 12 * i + 8, item.kind);
                });
            }
            put8(out + 8, 0);
            put8(out + 12, 0);
            return;
        }
        stateGlobCalls++;
        assert.equal(stringAt(root, rootLen), 'root');
        assert.equal(patternStr, '*');
        assert.deepEqual([hidden, ignored, directories, max], [0, 0, 0, 7n]);
        if (count) assert.deepEqual(Array.from({ length: count }, (_, i) => getText(paths + 8 * i)), ['nested/', 'other.txt']);
        const out = response(at, 32, 4);
        const list = listArea(out, 12, 1, 4);
        writeList(list, count === 0 ? 'bypassed.txt' : 'state-result.txt');
        put8(out + 8, 0);
        put8(out + 12, Number(count > 0));
        if (count) {
            put8(out + 16, 0); // entries
            put32(out + 20, 16384);
            put32(out + 24, 16385);
        }
    },
});
guestImports[sessionNs].eval = (scriptPtr, scriptLen, argsTag, argsPtr, argsLen, at) => {
    const script = stringAt(scriptPtr, scriptLen);
    assert.match(script, /vars::set_scoped\("glob_ignored", args\.glob_ignored, "visible", "persisted", \["client"\]\)/);
    assert.match(script, /refs::mount_host\(args\.agent_docs\)/);
    assert.equal(argsTag, 1);
    const parsed = JSON.parse(stringAt(argsPtr, argsLen));
    if (changeRejected) return opError(at, 2, 'fixture refusal');
    published = JSON.stringify(parsed.glob_ignored);
    mountedDocs = parsed.agent_docs;
    writeList(response(at, 16, 4), 'null');
};
guestImports[hostInfo]['host-info'] = at => writeList(response(at, 16, 4), hostJson);
guestImports[agentExecution].create = (channels, count, at) => {
    assert.equal(count, 3);
    assert.equal(getText(channels), 'result');
    put32(response(at, 28, 4), buffer);
};
guestImports[agentExecution]['[resource-drop]buffer'] = id => {
    assert.equal(id, buffer);
    dropCalls++;
};
const coding = new WebAssembly.Instance(guest, guestImports).exports;
({ memory, cabi_realloc: realloc } = coding);

for (const [reply, expected, expectedDocs] of [
    [['nested/', 'other.txt'], '["nested/","other.txt"]', ['AGENTS.md', 'nested/AGENTS.md']],
    [[], '[]', []],
    [4, '{"status":"incomplete","reason":"limit"}', []],
    [2, '{"status":"unavailable","reason":"unsupported"}', []],
]) {
    snapshotReply = reply;
    const result = coding.init();
    assert.equal(get8(result), 0);
    assert.equal(published, expected);
    assert.deepEqual(mountedDocs, expectedDocs);
    coding.cabi_post_init(result);
}
changeRejected = true;
let result = coding.init();
assert.equal(get8(result), 1);
assert.equal(getText(result + 4), 'denied');
assert.equal(getText(result + 12), 'could not publish glob_ignored: fixture refusal');
coding.cabi_post_init(result);
assert.equal(snapshotCalls, 5);
assert.equal(initDocGlobs, 2);

function glob(ignoredList) {
    return coding.invoke(...alloc(hostJson), ...alloc('glob'), ...alloc(JSON.stringify({
        root: 'root', pattern: '*', ignored_list: ignoredList, max_results: 7,
    })));
}
for (const bad of [undefined, null, { status: 'incomplete' }, [[65]]]) {
    result = glob(bad);
    assert.equal(get8(result), 1);
    assert.equal(getText(result + 8), 'invalid_request');
    assert.match(getText(result + 16), /resolved ignored_list array/);
    coding.cabi_post_invoke(result);
}
for (const [paths, file] of [[['nested/', 'other.txt'], 'state-result.txt'], [[], 'bypassed.txt']]) {
    result = glob(paths);
    assert.deepEqual([get8(result), get8(result + 4)], [0, 0]);
    const output = JSON.parse(getText(result + 8));
    assert.deepEqual(output.groups, [{ kind: 'file', path: [file] }]);
    assert.equal(output.truncated, false);
    if (paths.length === 0) assert.equal(output.scan_incomplete, undefined);
    else assert.deepEqual(output.scan_incomplete, {
        reason: 'entries', limit: 16384, observed: 16385,
        guidance: 'Use a narrower root or a pattern starting with a literal directory prefix. No matches in the scanned portion does not prove absence.',
    });
    coding.cabi_post_invoke(result);
}
assert.equal(stateGlobCalls, 2);
assert.equal(dropCalls, 6);
assert.equal(snapshotCalls, 5, 'glob does not re-collect ignore paths');
console.log('Coding production guest: resolved path init publication, atomic failures, strict path-list dispatch and separate scan diagnostics verified.');
