import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { runInNewContext } from 'node:vm';

const source = await readFile(process.argv[2]);
const module = await WebAssembly.compile(source);
const hostInfo = 'microcrab:agent/host-info@0.9.0';
const execution = 'microcrab:agent/execution@0.9.0';
const variables = 'microcrab:session/variables@0.2.0';
const references = 'microcrab:session/references@0.3.0';
const observer = 'microcrab:session/observation@0.2.2';
const debugObservation = process.argv.includes('--debug-observation');
const observations = [];
const checkpoints = [];
const browserObserver = 'microcrab:session/browser-observation@0.2.3';
const webTransport = 'microcrab:host/web-transport@0.1.0';
const webNames = ['http-get', 'ws-open', 'ws-status', 'ws-send', 'ws-receive', 'ws-close'];
const scopedWeb = 'microcrab:host/web-transport-scoped@0.1.1';
const scopedNames = ['ws-pull', 'ws-budget', 'ws-settle'];
const importKeys = WebAssembly.Module.imports(module).map(({module, name, kind}) => `${module}:${name}:${kind}`).sort();
assert.deepEqual(importKeys, [
    `${hostInfo}:host-info:function`, `${variables}:tool-call-facts:function`,
    ...['create', 'append', 'finish', 'attach-guest', '[resource-drop]buffer'].map(name => `${execution}:${name}:function`),
    `${references}:create:function`, `${observer}:record-event:function`, ...webNames.map(name => `${webTransport}:${name}:function`),
    ...scopedNames.map(name => `${scopedWeb}:${name}:function`),
    ...(debugObservation ? [`${browserObserver}:record-checkpoint:function`] : []),
].sort(), 'only required functions; no ambient host operations');
assert.deepEqual(WebAssembly.Module.exports(module).map(item => item.name).sort(), [
    'memory', 'cabi_realloc', 'init', 'describe', 'invoke', 'drive', 'cabi_post_init', 'cabi_post_describe',
    'cabi_post_invoke', 'cabi_post_drive',
].sort(), 'entryless wasm');

let exports;
let hostJson = '{"capabilities":[]}';
const endpoint = 'browser.test:9222';
const url = 'ws://browser.test:9222/devtools/browser/mock';
const endpointArg = { endpoint };
const discovery = JSON.stringify({ webSocketDebuggerUrl: url });
const calls = [];
const emitted = [];
const received = [];
let active = false;
let nextHandle = 0;
const jobs = new Map();
let connectionJob;
let nextBuffer = 40;
let nextBorrow = 500;
let pendingBorrow;
let drivenJob;
let rejectAttach = false;
let drivePulls = 0;
let receiveVariant = undefined;
let remainingTransport = 10_000;
let softEmptyWaits = 0;
const residual = [];
let settled = 0;
let sendError = undefined;
let coherent = true;
let admittedMode = 'observe'; // Independent of the caller's explicit policy Allow.
let factsCalls = 0;
let stagedBytes = [];
let rejectPrivateBytes = false;

const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8', { fatal: true });
const bytes = (at, len) => new Uint8Array(exports.memory.buffer, at, len);
const data = () => new DataView(exports.memory.buffer);
const text = (at, len) => decoder.decode(bytes(at, len));
const atText = at => text(data().getUint32(at, true), data().getUint32(at + 4, true));
function alloc(value) {
    const utf8 = encoder.encode(value);
    const at = exports.cabi_realloc(0, 0, 1, utf8.length);
    bytes(at, utf8.length).set(utf8);
    return [at, utf8.length];
}
function putText(out, value) {
    const [at, len] = alloc(value);
    data().setUint32(out, at, true);
    data().setUint32(out + 4, len, true);
}
function transport(name, fn) {
    return (...args) => {
        calls.push(name);
        return fn(...args);
    };
}
function verifyId(at, len) {
    assert.equal(text(at, len), `mock-${nextHandle}`);
    assert(active);
}
function operationOk(out) {
    bytes(out, 2).fill(0);
}

({ exports } = await WebAssembly.instantiate(module, {
    [hostInfo]: { 'host-info': out => {
        bytes(out, 16).fill(0);
        putText(out + 4, coherent ? hostJson : '{"capabilities":[]}');
    } },
    [execution]: {
        create: (capturesAt, capturesLen, out) => {
            assert.deepEqual([capturesAt, capturesLen, out % 4], [0, 0, 0]);
            assert(active, 'readiness buffer is created only after opening the socket');
            bytes(out, 28).fill(0);
            const buffer = ++nextBuffer;
            jobs.set(buffer, { buffer, initial: undefined, state: undefined, ownedDropped: false, published: [] });
            data().setUint32(out + 4, buffer, true);
        },
        append: (buffer, tag, channelAt, channelLen, contentAt, contentLen, out) => {
            assert.deepEqual([tag, channelAt, channelLen, out % 4], [0, 0, 0, 0]);
            const content = text(contentAt, contentLen);
            if (buffer === pendingBorrow) {
                assert(drivenJob && drivenJob.state && !drivenJob.ownedDropped);
                drivenJob.published.push(JSON.parse(content));
            } else {
                const job = jobs.get(buffer);
                assert(job && !job.ownedDropped && job.initial === undefined);
                job.initial = JSON.parse(content);
            }
            bytes(out, 28).fill(0);
        },
        'attach-guest': (buffer, at, len, out) => {
            assert.equal(out % 4, 0);
            verifyId(at, len);
            const job = jobs.get(buffer);
            assert(job && !job.ownedDropped && job.state === undefined);
            assert.deepEqual(job.initial, { status: 'connected', connect_id: text(at, len) });
            bytes(out, 28).fill(0);
            if (rejectAttach) {
                data().setUint8(out, 1);
                putText(out + 8, 'test_attach_rejected');
                putText(out + 16, 'fixture-only attach diagnostics');
                return;
            }
            job.state = text(at, len);
        },
        finish: (buffer, isSome, _kind, _codeAt, _codeLen, _msgAt, _msgLen, _retryable, out) => {
            assert.equal(isSome, 0);
            const job = jobs.get(buffer);
            assert(job && !job.ownedDropped);
            job.finished = true;
            bytes(out, 28).fill(0);
        },
        '[resource-drop]buffer': index => {
            if (pendingBorrow !== undefined) {
                assert.equal(index, pendingBorrow);
                pendingBorrow = undefined;
            } else {
                const job = jobs.get(index);
                assert(job && !job.ownedDropped && job.state === undefined);
                job.ownedDropped = true;
            }
        },
    },
    [observer]: { 'record-event': (...args) => {
        assert.equal(args.length, 8, 'fixed scalar canonical observation ABI');
        assert(args.every(Number.isInteger));
        observations.push(args.map(v => v >>> 0));
    } },
    [browserObserver]: { 'record-checkpoint': (...args) => {
        assert.equal(args.length, 4);
        assert(args.every(Number.isInteger));
        checkpoints.push(args);
    } },
    [variables]: { 'tool-call-facts': out => {
        assert.equal(out % 8, 0);
        factsCalls++;
        bytes(out, 40).fill(0);
        if (admittedMode === undefined) {
            data().setUint8(out, 1); // Err
            data().setUint8(out + 8, 1); // communication-error-code::unavailable
            putText(out + 12, 'no admitted tool invocation');
            return;
        }
        putText(out + 8, 'synthetic-session-🦀');
        if (admittedMode !== null) {
            data().setUint8(out + 16, 1);
            putText(out + 20, admittedMode);
        }
        data().setBigUint64(out + 32, 0xfedcba9876543210n, true);
    } },
    [references]: { create: (at, len, mediaAt, mediaLen, jpeg, jpegLen, out) => {
        assert.equal(out % 4, 0);
        assert.equal(emitted.at(-1).method, 'Target.detachFromTarget');
        assert.equal(received.length, 0, 'detach acknowledged before staging');
        const id = `ref_mock_${String(stagedBytes.length + 1).padStart(16, '0')}`;
        stagedBytes.push({ title: text(at, len), media_type: text(mediaAt, mediaLen), jpeg: Buffer.from(bytes(jpeg, jpegLen)), id });
        bytes(out, 12).fill(0);
        if (rejectPrivateBytes) {
            data().setUint8(out, 1);
            putText(out + 4, 'private fixture diagnostics');
        } else {
            putText(out + 4, id);
        }
    } },
    [webTransport]: {
        'http-get': transport('http-get', (at, len, cap, out) => {
            assert.equal(text(at, len), `http://${endpoint}/json/version`);
            assert.equal(cap, 16 * 1024);
            bytes(out, 16).fill(0);
            data().setUint16(out + 4, 200, true);
            putText(out + 8, discovery);
        }),
        'ws-open': transport('ws-open', (at, len, out) => {
            assert.equal(text(at, len), url);
            bytes(out, 12).fill(0);
            if (active) {
                // Match Runtime admission: reject a second exact live scope.
                data().setUint8(out, 1);
                data().setUint8(out + 4, 1); // denied
                return;
            }
            nextHandle++;
            active = true;
            putText(out + 4, `mock-${nextHandle}`);
        }),
        'ws-status': transport('ws-status', (at, len, out) => { verifyId(at, len); operationOk(out); }),
        'ws-send': transport('ws-send', (at, len, payload, size, out) => {
            verifyId(at, len);
            emitted.push(JSON.parse(text(payload, size)));
            operationOk(out);
            if (sendError !== undefined) bytes(out, 2).set([1, sendError]);
        }),
        'ws-receive': transport('ws-receive', (at, len, cap, out) => {
            verifyId(at, len);
            assert.equal(cap, 256 * 1024);
            bytes(out, 16).fill(0);
            if (receiveVariant !== undefined) {
                data().setUint8(out + 4, receiveVariant);
                return;
            }
            assert(received.length);
            putText(out + 8, JSON.stringify(received.shift()));
        }),
        'ws-close': transport('ws-close', (at, len, out) => { verifyId(at, len); operationOk(out); active = false; }),
    },
    [scopedWeb]: {
        'ws-budget': (at, len, out) => {
            verifyId(at, len);
            bytes(out, 12).fill(0);
            data().setUint32(out + 4, remainingTransport, true);
            data().setUint32(out + 8, 2000, true);
        },
        'ws-pull': (at, len, cap, soft, out) => {
            verifyId(at, len);
            assert.equal(cap, 256 * 1024);
            assert(soft >= 0 && soft <= 1000);
            bytes(out, 16).fill(0);
            if (pendingBorrow !== undefined) {
                assert.equal(soft, 0, 'drive may only pull opportunistically');
                drivePulls++;
            }
            if (soft === 0) {
                if (residual.length) putText(out + 8, JSON.stringify(residual.shift()));
                else data().setUint8(out + 4, 1);
                return;
            }
            calls.push('ws-receive'); // fixture accounting for nonzero waits
            if (receiveVariant !== undefined) {
                bytes(out, 16).set([1]);
                data().setUint8(out + 4, receiveVariant === 1 ? 5 : 7);
                return;
            }
            if (softEmptyWaits > 0) {
                softEmptyWaits--;
                remainingTransport -= soft;
                data().setUint8(out + 4, 1);
                return;
            }
            assert(received.length);
            putText(out + 8, JSON.stringify(received.shift()));
        },
        'ws-settle': (at, len, out) => { verifyId(at, len); assert.equal(residual.length, 0); settled++; operationOk(out); },
    },
}));

function describe() {
    const out = exports.describe(...alloc(hostJson));
    assert.equal(data().getUint8(out), 0);
    const value = JSON.parse(atText(out + 4));
    exports.cabi_post_describe(out);
    return value;
}
function invoke(name, args = {}) {
    const out = exports.invoke(...alloc(hostJson), ...alloc(name), ...alloc(JSON.stringify(args)));
    let result;
    if (data().getUint8(out) === 0) {
        if (name === 'connect') {
            assert.equal(data().getUint8(out + 4), 1, 'Buffered');
            assert.equal(data().getUint8(out + 12), 1, 'include-initial');
            const buffer = data().getUint32(out + 8, true);
            result = jobs.get(buffer);
            assert(result && result.state && !result.ownedDropped, 'return the owned, attached buffer');
            assert.notEqual(result.initial.connect_id, String(buffer), 'Job and connection IDs serve different roles');
        } else if (data().getUint8(out + 4) === 1) {
            assert.equal(data().getUint8(out + 12), 1, 'include-initial');
            const buffer = data().getUint32(out + 8, true);
            const job = jobs.get(buffer);
            assert(job && job.finished && !job.ownedDropped, 'return the owned, finished buffer');
            result = job.initial;
        } else {
            assert.equal(data().getUint8(out + 4), 0, 'Final');
            assert.equal(data().getUint8(out + 16), 0, 'no embedded failure');
            assert.equal(data().getUint32(out + 48, true), 0, 'no attachments');
            result = JSON.parse(atText(out + 8));
        }
    } else {
        result = {
            kind: data().getUint8(out + 4),
            code: atText(out + 8),
            message: atText(out + 16),
        };
        assert.equal(data().getUint8(out + 24), 0, 'never retryable');
    }
    exports.cabi_post_invoke(out);
    return result;
}

// Only the raw ABI helper can omit/spoof the required ID. Normal fixtures
// explicitly wire the exact receipt ID, never the resource representation.
function onConnection(name, args, connectId = connectionJob.initial.connect_id) {
    return invoke(name, { ...args, connect_id: connectId });
}
function connect(args = { endpoint: url }) {
    assert.equal(received.length, 0);
    received.push(version);
    const job = invoke('connect', args);
    assert.deepEqual(job.initial, { status: 'connected', connect_id: `mock-${nextHandle}` });
    assert.equal(job.state, job.initial.connect_id);
    assert.equal(received.length, 0, 'connect consumes only the solicited handshake reply');
    connectionJob = job;
    return job;
}
function drive(job, cancelled = false, state = job.state) {
    pendingBorrow = ++nextBorrow;
    drivenJob = job;
    const commands = emitted.length;
    const out = exports.drive(pendingBorrow, ...alloc(state), Number(cancelled));
    assert.equal(out % 8, 0);
    assert.equal(data().getUint8(out), 0, 'drive succeeded');
    const step = { state: atText(out + 8), delay: data().getBigUint64(out + 16, true), finished: data().getUint8(out + 24) };
    exports.cabi_post_drive(out);
    assert.equal(pendingBorrow, undefined, 'drive drops its resource representation exactly once');
    drivenJob = undefined;
    assert.equal(emitted.length, commands, 'no autonomous CDP commands');
    return step;
}
function cancelConnection(job) {
    const pulls = drivePulls;
    const transportCalls = calls.length;
    assert.deepEqual(drive(job, true), { state: '', delay: 0n, finished: 1 });
    assert.equal(drivePulls, pulls, 'cancelled drive does not receive');
    assert.equal(calls.length, transportCalls, 'Runtime, not drive, owns exact socket cleanup');
    assert.equal(active, true, 'guest completion alone is not a Host cleanup acknowledgement');
    assert.equal(job.state, `mock-${nextHandle}`, 'Runtime cleanup targets only the retained scope');
    active = false; // Mock the Runtime/Host cleanup ACK for this exact connection.
}

const init = exports.init();
assert.equal(data().getUint8(init), 0);
exports.cabi_post_init(init);
const [agent] = describe();
assert.equal(agent.name, 'browser');
const expectedTools = ['connect', 'status', 'list_pages', 'snapshot', 'click', 'type_text', 'navigate', 'screenshot', 'press_key',
    'new_tab', 'select_tab', 'history_navigation', 'close_tab', 'scroll', 'find', 'set_checked', 'select_option', 'wait_for', 'webmcp_list', 'webmcp_invoke',
    'configure_connection', 'read_network_detail', 'execute_js'];
const askInInteraction = ['configure_connection', 'read_network_detail', 'webmcp_invoke'];
assert.deepEqual(Object.keys(agent.tools.at(-3).parameters.properties), ['connect_id', 'page_ref', 'network_enabled', 'url_prefix', 'body_url_prefix']);
assert.deepEqual(Object.keys(agent.tools.at(-2).parameters.properties), ['connect_id', 'page_ref', 'record_id', 'include_body']);
const { world: jsWorld, timeout_ms: jsTimeout } = agent.tools.at(-1).parameters.properties;
assert.deepEqual(jsWorld, { type: 'string', enum: ['isolated', 'main'], default: 'isolated' });
assert.deepEqual(jsTimeout, { type: 'integer', minimum: 1, maximum: 2000, default: 1000 });
assert.deepEqual(agent.tools.map(tool => tool.name), expectedTools);
assert.deepEqual(agent.tools.map(tool => tool.parameters.required), [
    ['endpoint'], [], [], ['page_ref'], ['page_ref', 'element_ref'], ['page_ref', 'element_ref', 'text'], ['page_ref', 'url'],
    ['page_ref'], ['page_ref', 'element_ref', 'key'], [], ['page_ref'], ['page_ref', 'action'],
    ['page_ref'], ['page_ref', 'delta_y'], ['page_ref'], ['page_ref', 'element_ref', 'checked'],
    ['page_ref', 'element_ref', 'value'], ['page_ref', 'timeout_ms', 'condition'], ['page_ref'], ['page_ref', 'tool_ref', 'input'],
    ['page_ref', 'network_enabled'], ['page_ref', 'record_id'], ['page_ref', 'expression'],
].map((required, index) => index ? ['connect_id', ...required] : required));
assert.deepEqual(Object.keys(agent.tools[3].parameters.properties), ['connect_id', 'page_ref', 'region_ref']);
const framing = agent.tools[7].parameters.properties;
assert.deepEqual(Object.keys(framing), ['connect_id', 'page_ref', 'title', 'clip', 'scale', 'quality']);
assert.equal(framing.clip.additionalProperties, false);
assert.deepEqual(framing.clip.required, ['x', 'y', 'width', 'height']);
assert.deepEqual(framing.clip.properties, {
    x: { type: 'number', minimum: 0 }, y: { type: 'number', minimum: 0 },
    width: { type: 'number', exclusiveMinimum: 0 }, height: { type: 'number', exclusiveMinimum: 0 },
});
assert.deepEqual([framing.scale.type, framing.scale.minimum, framing.scale.maximum], ['number', 0.1, 1]);
assert.deepEqual(framing.quality, { type: 'integer', minimum: 0, maximum: 100, default: 55 });
const pageRefSchema = { type: 'string', pattern: '^[a-f0-9]{32}$' };
const connectIdSchema = { type: 'string', pattern: '^[A-Za-z0-9_-]+$', maxLength: 128, description: 'The exact opaque connect_id for this Browser connection.' };
assert.deepEqual(agent.tools.slice(9, 12).map(tool => tool.parameters.properties), [
    { connect_id: connectIdSchema, url: { type: 'string', minLength: 1, maxLength: 4096 } },
    { connect_id: connectIdSchema, page_ref: pageRefSchema },
    { connect_id: connectIdSchema, page_ref: pageRefSchema, action: { type: 'string', enum: ['reload', 'back', 'forward'] } },
]);
assert.deepEqual(agent.tool_bindings, Object.fromEntries(expectedTools.map(name => [name, {
    web: name === 'connect'
        ? { kind: 'open', endpoint: '/endpoint', handoff: true }
        : { kind: 'existing', connection: '/connect_id', send: name !== 'status' },
    exact_arguments: name === 'execute_js' ? ['/world', '/expression', '/page_ref'] : ['navigate', 'new_tab'].includes(name) ? ['/url'] : [],
}])));
for (const tool of agent.tools.slice(1)) assert.deepEqual(tool.parameters.properties.connect_id, connectIdSchema);
assert(agent.tools.every(tool => tool.parameters.additionalProperties === false));
assert.deepEqual(agent.modes.map(mode => [mode.name, mode.role]), [['observe', 'main_agent'], ['interaction', 'main_agent']]);
for (const [index, actions] of [
    ['allow', 'allow', 'allow', 'allow', 'deny', 'deny', 'deny', 'allow', 'deny', 'deny', 'deny', 'deny',
        'deny', 'deny', 'allow', 'deny', 'deny', 'allow', 'allow', 'deny', 'allow', 'allow', 'deny'],
    expectedTools.map(tool => askInInteraction.includes(tool) ? 'ask' : 'allow'),
].entries()) {
    const mode = agent.modes[index];
    assert.equal(mode.prompt, undefined);
    const base = expectedTools.map((value, i) => ({ agent: 'browser', mode: mode.name, tool: { kind: 'exact', value }, action: actions[i] }));
    if (mode.name === 'interaction') base.push({
        agent: 'browser', mode: 'interaction', tool: { kind: 'exact', value: 'execute_js' }, action: 'ask',
        args: [{ pointer: '/world', matcher: { kind: 'exact', value: 'main' } }],
    });
    assert.deepEqual(mode.permissions, base);
}
assert.equal(agent.variables.rules.length, 1);
assert.match(agent.variables.rules[0].description, /HTTPS and loopback HTTP.*Confirm non-loopback HTTP.*does not apply to direct WS\(S\)/);
assert.match(agent.variables.hints[0].description, /connect_id.*separate Job handle.*Job\.read.*later Buffered output/);
assert.match(agent.variables.hints[1].description, /transport is bounded.*smallest region.*scale and JPEG quality.*Avoid full-viewport high-quality/);
for (const example of ['localhost:9222', 'https://browser.example:9222/', 'devtools/discover?profile=work', 'wss://browser.example:9222/devtools/browser/abc']) {
    assert(agent.tools[0].description.includes(example));
}
assert.equal(invoke('connect', endpointArg).code, 'unsupported');
assert.deepEqual(calls, [], 'init/describe/unsupported never call web transport');

hostJson = '{"capabilities":["web_transport"]}';
assert.deepEqual(describe(), [agent]);
coherent = false;
assert.equal(invoke('connect', endpointArg).code, 'invalid_host_info');
coherent = true;
assert.equal(invoke('connect', { ...endpointArg, unsafe: true }).code, 'invalid_request');
assert.equal(invoke('connect', 'bad').code, 'invalid_request');
assert.equal(invoke('cdp_call', { method: 'Runtime.evaluate' }).code, 'invalid_request');
assert.equal(invoke('status').code, 'invalid_request', 'status also requires connect_id');
assert.equal(onConnection('status', {}, 'unissued-id').code, 'stale_connection');
assert.equal(factsCalls, 0, 'discovery and non-effect tools do not request invocation facts');
assert.deepEqual(calls, []);

const pageRef = 'a'.repeat(32);
const elementRef = 'b'.repeat(32);
const effects = [
    ['click', { page_ref: pageRef, element_ref: elementRef }],
    ['type_text', { page_ref: pageRef, element_ref: elementRef, text: 'synthetic input' }],
    ['navigate', { page_ref: pageRef, url: 'https://fixture.test/explicit' }],
    ['press_key', { page_ref: pageRef, element_ref: elementRef, key: 'Enter' }],
    ['new_tab', {}],
    ['new_tab', { url: 'https://fixture.test/explicit' }],
    ['select_tab', { page_ref: pageRef }],
    ...['reload', 'back', 'forward'].map(action => ['history_navigation', { page_ref: pageRef, action }]),
    ['close_tab', { page_ref: pageRef }],
    ['scroll', { page_ref: pageRef, delta_y: 50 }],
    ['set_checked', { page_ref: pageRef, element_ref: elementRef, checked: false }],
    ['select_option', { page_ref: pageRef, element_ref: elementRef, value: '' }],
    ['webmcp_invoke', { page_ref: pageRef, tool_ref: elementRef, input: {} }],
    ['execute_js', { page_ref: pageRef, expression: '1 + 1' }],
    ['execute_js', { page_ref: pageRef, expression: 'document.title', world: 'main' }],
];
// The harness dispatches directly, as if ordinary tool policy already allowed
// this exact call. Only typed runtime facts may authorize the guest effect.
for (const mode of ['observe', null, undefined, 'interaction ', 'different']) {
    admittedMode = mode;
    for (const [name, args] of effects) {
        assert.equal(onConnection(name, args, 'unissued-id').code, 'mode_required', `${name} in ${mode}`);
    }
}
assert.equal(factsCalls, 5 * effects.length);
assert.deepEqual(calls, [], 'refusal precedes any browser transport');
admittedMode = 'interaction';
assert.equal(onConnection('navigate', effects[2][1], 'unissued-id').code, 'stale_connection', 'typed interaction admission reaches the browser boundary');
assert.deepEqual(calls, []);
admittedMode = 'observe';

const version = { id: 1, result: { product: 'Synthetic Browser', protocolVersion: '1.3' } };
const targetInfos = [{ type: 'page', targetId: 'wire-target', title: 'click\u0000 now', url: 'https://fixture.test' }];
const snapshotElement = '0123456789abcdef0123456789abcdef';
const witness = { sessionId: 'wire-session', method: 'Runtime.executionContextCreated', params: { context: {
    id: 42, name: 'microcrab-observe-mock-1', uniqueId: 'wire-unique',
    auxData: { frameId: 'wire-target', type: 'isolated', isDefault: false },
} } };
function scopedOperation(first, value) {
    return [
        { id: first, result: { targetInfos } },
        { id: first + 1, result: { sessionId: 'wire-session' } },
        { id: first + 2, sessionId: 'wire-session', result: { executionContextId: 42 } },
        witness,
        { id: first + 3, sessionId: 'wire-session', result: {} },
        { id: first + 4, sessionId: 'wire-session', result: {} },
        { id: first + 5, sessionId: 'wire-session', result: { result: { value } } },
        { id: first + 6, result: {} },
    ];
}
const firstJob = connect(endpointArg);
assert.deepEqual(calls, ['http-get', 'ws-open', 'ws-send', 'ws-receive']);
const initialJobs = jobs.size;
const initialCommands = emitted.length;
assert.equal(invoke('connect', { endpoint: url }).code, 'denied');
assert.equal(emitted.length, initialCommands, 'duplicate connect does not send or close');
assert(active);
const initialCalls = calls.length;
assert.equal(invoke('list_pages').code, 'invalid_request');
for (const badId of [null, firstJob.buffer, '', 'slash/id', 'a'.repeat(129)]) {
    assert.equal(invoke('list_pages', { connect_id: badId }).code, 'invalid_request');
}
assert.equal(onConnection('list_pages', {}, String(firstJob.buffer)).code, 'stale_connection');
assert.equal(calls.length, initialCalls, 'bad IDs have no transport effects');
assert.equal(jobs.size, initialJobs, 'duplicate connect has no second Job');
assert.deepEqual(drive(firstJob, false, 'wrong-generation'), { state: '', delay: 0n, finished: 1 });
const firstPull = drivePulls;
const firstDriveCalls = calls.length;
residual.push(...Array(17).fill({ method: 'fixture.idleEvent', params: { data: 'not a Job summary' } }));
const paced = drive(firstJob);
assert.equal(paced.state, firstJob.state);
assert.equal(paced.finished, 0);
assert(paced.delay > 0n);
assert(drivePulls > firstPull && residual.length > 0, 'drive drains only a bounded slice');
const idle = drive(firstJob);
assert.equal(idle.state, firstJob.state);
assert.equal(idle.finished, 0);
assert(idle.delay > paced.delay, 'empty receive is paced more slowly');
assert.equal(residual.length, 0, 'idle drive consumes events before any foreground tool');
assert.equal(calls.length, firstDriveCalls, 'idle drive only uses scoped opportunistic pulls');
received.push({ id: 2, result: { targetInfos } }, ...scopedOperation(3, {
    rows: [{ r: 'button', n: 'Synthetic Save', ref: snapshotElement }], visited: 2,
    continuation: null, coverage: 'end_of_scope', presentationLimited: false,
}));
assert.deepEqual(onConnection('status'), { status: 'connected' });
const pages = onConnection('list_pages');
assert(pages.pages[0].ref.match(/^[a-f0-9]{32}$/));
assert.equal(pages.pages[0].title, targetInfos[0].title);
const snapshot = onConnection('snapshot', { page_ref: pages.pages[0].ref });
assert.equal(snapshot.rows[0].name, 'Synthetic Save');
assert.equal(snapshot.rows[0].ref, snapshotElement);
assert.equal(snapshot.coverage, 'end_of_scope');
assert(!JSON.stringify([pages, snapshot]).includes('wire-'));
const scopedMethods = ['Target.getTargets', 'Target.attachToTarget', 'Page.createIsolatedWorld',
    'Runtime.enable', 'Runtime.disable', 'Runtime.callFunctionOn', 'Target.detachFromTarget'];
assert.deepEqual(emitted.map(cmd => cmd.method), ['Browser.getVersion', 'Target.getTargets', ...scopedMethods]);
assert.equal(emitted[7].params.uniqueContextId, 'wire-unique');
assert.equal(emitted[7].params.executionContextId, undefined);
assert.equal(received.length, 0);
assert.deepEqual(calls.slice(0, 6), ['http-get', 'ws-open', 'ws-send', 'ws-receive', 'ws-open', 'ws-status']);

const page_ref = pages.pages[0].ref;
const beforeDenied = calls.length;
assert.equal(onConnection('click', { page_ref, element_ref: snapshotElement }).code, 'mode_required');
assert.equal(calls.length, beforeDenied, 'observe cannot click an actual, currently scoped element');

admittedMode = 'interaction';
received.push(...scopedOperation(10, { outcome: 'click_dispatched' }));
assert.deepEqual(onConnection('click', { page_ref, element_ref: snapshotElement }), { outcome: 'click_dispatched' });
assert.deepEqual(emitted.slice(9).map(cmd => cmd.method), scopedMethods);
assert.deepEqual(emitted[14].params.arguments.slice(1).map(arg => arg.value), ['click', snapshotElement, null]);
assert.equal(received.length, 0);

const keyArgs = { page_ref, element_ref: snapshotElement, key: 'K', modifiers: ['Control', 'Shift'] };
const beforeInvalid = emitted.length;
assert.equal(onConnection('press_key', { ...keyArgs, key: 'invalid named key' }).code, 'invalid_key');
assert.equal(onConnection('press_key', { ...keyArgs, modifiers: ['Alt', 'Alt'] }).code, 'invalid_key');
assert.equal(emitted.length, beforeInvalid);
received.push(...scopedOperation(17, { outcome: 'keys_dispatched' }));
assert.deepEqual(onConnection('press_key', keyArgs), { outcome: 'keys_dispatched' });
const keyCall = emitted.at(-2);
assert.deepEqual(keyCall.params.arguments.slice(1, 3).map(arg => arg.value), ['key', snapshotElement]);
assert.deepEqual(JSON.parse(keyCall.params.arguments[3].value), { key: 'K', ctrlKey: true, altKey: false, shiftKey: true, metaKey: false });
// Exercise the actual fixed script in a synthetic DOM, rather than only
// accepting the mocked CDP receipt. The target is already scoped by snapshot.
{
    const events = [];
    const document = { documentElement: {}, URL: 'https://fixture.test', location: { protocol: 'https:' }, getElementById: () => null };
    const parentElement = {};
    let moveOnDown = false;
    const el = {
        isConnected: true, ownerDocument: document, parentElement, localName: 'button',
        getAttribute: () => null, hasAttribute: () => false, closest: () => null,
        matches: () => false, checkVisibility: () => true,
        dispatchEvent: event => { events.push(event); if (moveOnDown) el.parentElement = {}; },
    };
    const context = { document, KeyboardEvent: class { constructor(type, options) { Object.assign(this, { type, ...options }); } } };
    context['microcrab-observe-mock-1'] = { root: document.documentElement, url: document.URL, refs: new Map([[snapshotElement, { kind: 'node', node: el, parent: parentElement, role: 'button', label: '' }]]) };
    const run = '(' + keyCall.params.functionDeclaration + ')(...args)';
    context.args = keyCall.params.arguments.map(arg => arg.value);
    assert.equal(runInNewContext('globalThis.top = globalThis; ' + run, context).outcome, 'keys_dispatched');
    assert.deepEqual(events.map(({ type, key, ctrlKey, shiftKey }) => [type, key, ctrlKey, shiftKey]), [['keydown', 'K', true, true], ['keyup', 'K', true, true]]);
    moveOnDown = true;
    assert.equal(runInNewContext(run, context).outcome, 'keydown_dispatched_unconfirmed');
    assert.equal(events.length, 3, 'do not dispatch keyup after a move');
}

function screenshotReplies(id, jpeg, detach = { result: {} }) {
    return [
        { id, result: { targetInfos } },
        { id: id + 1, result: { sessionId: 'wire-session' } },
        { method: 'fixture.event', params: { data: 'unrelated string' } },
        { result: { data: jpeg.toString('base64') }, sessionId: 'wire-session', id: id + 2 },
        { id: id + 3, ...detach },
    ];
}
function framedJpeg(len) {
    const jpeg = Buffer.alloc(len, 0x3f);
    // Synthetic SOI + baseline frame header, 1 component, 32×16 pixels.
    jpeg.set([0xff, 0xd8, 0xff, 0xc0, 0, 11, 8, 0, 16, 0, 32, 1, 1, 0x11, 0]);
    jpeg.set([0xff, 0xd9], len - 2);
    return jpeg;
}
const destination = { page_ref, title: 'shot.test-1' };
assert.equal(onConnection('screenshot', { ...destination, path: 'no.jpg' }).code, 'invalid_request');
assert.equal(onConnection('screenshot', {}).code, 'invalid_request');
assert.equal(onConnection('screenshot', { ...destination, title: null }).code, 'invalid_request');
assert.equal(onConnection('screenshot', { ...destination, title: '' }).code, 'invalid_title');
assert.deepEqual(stagedBytes, []);
const priorCommands = emitted.length;
const testClip = { x: 12.25, y: 20, width: 200, height: 100 };
for (const options of [
    { clip: null }, { clip: false }, { clip: { x: 0, y: 0, width: 1 } },
    { clip: { ...testClip, width: '200' } }, { clip: { ...testClip, scale: 0.5 } },
    { scale: null }, { scale: '0.5' }, { quality: null }, { quality: '5' }, { quality: 50.5 },
]) assert.equal(onConnection('screenshot', { ...destination, ...options }).code, 'invalid_request');
for (const options of [
    { clip: { ...testClip, x: -1 } }, { clip: { ...testClip, width: 0 } },
    { clip: { ...testClip, width: 1 }, scale: 0.1 }, { scale: 0.099 }, { scale: 1.1 }, { quality: 101 },
]) assert.equal(onConnection('screenshot', { ...destination, ...options }).code, 'invalid_screenshot_options');
assert.equal(emitted.length, priorCommands, 'shape, ranges, and empty dimensions are rejected before transport');
admittedMode = 'observe';
const jpeg = framedJpeg(112 * 1024);
received.push(...screenshotReplies(24, jpeg));
assert.deepEqual(onConnection('screenshot', destination), {
    storage: 'personal_library', id: 'ref_mock_0000000000000001', title: destination.title, media_type: 'image/jpeg', bytes: jpeg.length, width: 32, height: 16,
});
assert.deepEqual(emitted.slice(-4).map(cmd => cmd.method), ['Target.getTargets', 'Target.attachToTarget', 'Page.captureScreenshot', 'Target.detachFromTarget']);
assert.deepEqual(emitted.at(-2).params, { format: 'jpeg', quality: 55, fromSurface: true, captureBeyondViewport: false });
assert.deepEqual(stagedBytes, [{ title: destination.title, media_type: 'image/jpeg', jpeg, id: 'ref_mock_0000000000000001' }]);
assert.equal(received.length, 0);
received.push(...screenshotReplies(28, framedJpeg(jpeg.length + 1)));
const jpegLimit = onConnection('screenshot', destination);
assert.equal(jpegLimit.code, 'screenshot_limit');
assert.match(jpegLimit.message, /smaller clip, lower scale, or lower quality/);
assert.equal(emitted.at(-1).method, 'Target.detachFromTarget');
assert.deepEqual(onConnection('status'), { status: 'connected' }, 'guest detached after JPEG limit');
assert.equal(stagedBytes.length, 1);
received.push(...screenshotReplies(32, Buffer.from('not jpeg')));
assert.equal(onConnection('screenshot', destination).code, 'invalid_screenshot');
assert.equal(stagedBytes.length, 1);
rejectPrivateBytes = true;
received.push(...screenshotReplies(36, framedJpeg(17)));
const rejection = onConnection('screenshot', destination);
assert.equal(rejection.code, 'reference_rejected');
assert(!rejection.message.includes('fixture diagnostics'));
assert.equal(stagedBytes.length, 2);
rejectPrivateBytes = false;

const visual = { pageX: 3, pageY: 400, clientWidth: 785, clientHeight: 600, scale: 1, zoom: 1 };
let nextId = 40;
function framingReplies(metrics, capture = true) {
    const id = nextId;
    nextId += capture ? 5 : 4;
    received.push({ id, result: { targetInfos } }, { id: id + 1, result: { sessionId: 'wire-session' } });
    received.push({ id: id + 2, sessionId: 'wire-session', result: metrics });
    if (capture) received.push({ id: id + 3, sessionId: 'wire-session', result: { data: framedJpeg(17).toString('base64') } });
    received.push({ id: nextId - 1, result: {} });
}
for (const [options, expectedClip] of [
    [{ clip: testClip }, { ...testClip, x: 15.25, y: 420, scale: 1 }],
    [{ scale: 0.1 }, { x: 3, y: 400, width: 785, height: 600, scale: 0.1 }],
    [{ clip: testClip, scale: 0.5 }, { ...testClip, x: 15.25, y: 420, scale: 0.5 }],
]) {
    framingReplies({ cssVisualViewport: visual });
    assert.equal(onConnection('screenshot', { ...destination, ...options }).bytes, 17);
    assert.deepEqual(emitted.slice(-5).map(cmd => cmd.method), ['Target.getTargets', 'Target.attachToTarget', 'Page.getLayoutMetrics', 'Page.captureScreenshot', 'Target.detachFromTarget']);
    assert.equal(emitted.at(-3).sessionId, 'wire-session');
    assert.deepEqual(emitted.at(-2).params, { format: 'jpeg', quality: 55, fromSurface: true, captureBeyondViewport: false, clip: expectedClip });
}
for (const quality of [0, 100]) {
    received.push(...screenshotReplies(nextId, framedJpeg(17)));
    nextId += 4;
    assert.equal(onConnection('screenshot', { ...destination, quality }).bytes, 17);
    assert.equal(emitted.at(-3).method, 'Target.attachToTarget', 'quality alone does not request metrics');
    assert.deepEqual(emitted.at(-2).params, { format: 'jpeg', quality, fromSurface: true, captureBeyondViewport: false });
}
const successfulStages = stagedBytes.length;
for (const [metrics, clip, expected] of [
    [{ cssVisualViewport: visual }, { ...testClip, width: 785 }, 'screenshot_clip_out_of_bounds'],
    [{ visualViewport: visual }, testClip, 'screenshot_geometry_unavailable'],
    ...[
        { zoom: undefined }, { zoom: 1.25 }, { scale: 1.25 }, { clientWidth: 0 },
        { pageY: -1 }, { pageY: 1e99 }, { pageY: '400' }, { clientHeight: null },
    ].map(patch => [{ cssVisualViewport: { ...visual, ...patch } }, testClip, 'screenshot_geometry_unavailable']),
    [{ cssVisualViewport: { ...visual, clientWidth: 8192, clientHeight: 4096 } }, { x: 0, y: 0, width: 8192, height: 4096 }, 'invalid_screenshot_options'],
]) {
    framingReplies(metrics, false);
    assert.equal(onConnection('screenshot', { ...destination, clip }).code, expected);
    assert.deepEqual(emitted.slice(-2).map(cmd => cmd.method), ['Page.getLayoutMetrics', 'Target.detachFromTarget']);
    assert.equal(stagedBytes.length, successfulStages, 'rejected geometry does not stage');
}
received.push(...screenshotReplies(nextId, framedJpeg(17), { error: { code: -1, message: 'fixture detach failure' } }));
assert.equal(onConnection('screenshot', destination).code, 'attachment_cleanup_failed');
assert.equal(stagedBytes.length, successfulStages, 'never stages after an unconfirmed detach');
assert.equal(onConnection('status').code, 'stale_connection');
connect();
received.push({ id: 2, result: { targetInfos } });
const renewedRef = onConnection('list_pages').pages[0].ref;
assert.notEqual(renewedRef, page_ref, 'the same target has a new connection-scoped reference');
assert.equal(onConnection('list_pages', {}, firstJob.state).code, 'stale_connection');
assert.deepEqual(drive(firstJob, true), { state: '', delay: 0n, finished: 1 }, 'stale cancellation leaves the new generation alone');
assert.deepEqual(onConnection('status'), { status: 'connected' });
received.push(...screenshotReplies(3, framedJpeg(17)).slice(0, 2), { id: 5, sessionId: 'wire-session', result: { data: 'a'.repeat(256 * 1024) } });
const wireLimit = onConnection('screenshot', { ...destination, page_ref: renewedRef });
assert.equal(wireLimit.code, 'screenshot_wire_limit');
assert.match(wireLimit.message, /explicitly reconnect/i);
assert.equal(emitted.at(-1).method, 'Page.captureScreenshot', 'cannot detach an unusable socket');
assert.equal(onConnection('status').code, 'stale_connection');
assert.equal(stagedBytes.length, successfulStages);
assert.equal(nextHandle, 2, 'wire oversize did not reconnect');
connect();
receiveVariant = 1;
assert.equal(onConnection('list_pages').kind, 1, 'receive timeout variant');
assert.equal(onConnection('status').code, 'stale_connection');
assert.equal(onConnection('list_pages').code, 'stale_connection');
assert.equal(nextHandle, 3, 'no implicit reconnect');
receiveVariant = undefined;
connect();
sendError = 8;
assert.equal(onConnection('list_pages').code, 'outcome_unknown');
assert.equal(nextHandle, 4, 'only explicit attempts');

// Use a fresh disposable connection for the exact tab and history sequences.
sendError = undefined;
admittedMode = 'interaction';
connect();
const beforeTabValidation = emitted.length;
for (const url of [null, 7, false]) assert.equal(onConnection('new_tab', { url }).code, 'invalid_request');
for (const url of ['', 'about:blank', 'chrome://newtab/', 'file:///tmp/test', 'javascript:alert(1)',
    'https://user:pass@fixture.test/', 'https://fixture.test\\@other.test/', 'https://fixture.test/a\nb',
    'https://fixture.test/' + 'x'.repeat(4096)]) {
    assert.equal(onConnection('new_tab', { url }).code, 'invalid_navigation_url');
}
assert.equal(onConnection('new_tab', { newWindow: true }).code, 'invalid_request');
assert.equal(onConnection('select_tab', { page_ref: 'a'.repeat(31) }).code, 'invalid_page_ref');
for (const action of ['0', 0, null, 'GoBack']) {
    assert.equal(onConnection('history_navigation', { page_ref, action }).code, 'invalid_request');
}
assert.equal(emitted.length, beforeTabValidation, 'bad tab inputs stop before transport');
const tabs = [{ type: 'page', targetId: 'created-tab', title: 'about:blank', url: 'about:blank' },
    { type: 'page', targetId: 'explicit-tab', title: 'Fixture', url: 'https://fixture.test/path?x=%20#kept' },
    ...targetInfos];
nextId = 2;
function browserReply(result) { received.push({ id: nextId++, result }); }
function pageReply(result) { received.push({ sessionId: 'wire-session', id: nextId++, result }); }
browserReply({ targetId: tabs[0].targetId });
const blank = onConnection('new_tab');
assert.equal(blank.outcome, 'tab_created');
assert.match(blank.page_ref, /^[a-f0-9]{32}$/);
assert.deepEqual(emitted.at(-1), { id: 2, method: 'Target.createTarget', params: { url: 'about:blank', newWindow: false, forTab: false } });
browserReply({ targetId: tabs[1].targetId });
const explicit = onConnection('new_tab', { url: tabs[1].url });
assert.equal(explicit.outcome, 'tab_created');
assert.notEqual(explicit.page_ref, blank.page_ref);
assert.equal(emitted.at(-1).params.url, tabs[1].url, 'preserve the exact explicit URL');
browserReply({ targetInfos: tabs });
browserReply({});
assert.deepEqual(onConnection('select_tab', { page_ref: blank.page_ref }), { outcome: 'tab_activation_requested', page_ref: blank.page_ref });
assert.deepEqual(emitted.at(-1), { id: 5, method: 'Target.activateTarget', params: { targetId: tabs[0].targetId } });
browserReply({ targetInfos: tabs });
const listed = onConnection('list_pages');
assert.deepEqual(listed.pages.slice(0, 2).map(page => page.ref), [blank.page_ref, explicit.page_ref]);

// Activation never overrides explicit page references; history is attached to
// the second tab even though the first tab was selected above.
function historySetup(result) {
    browserReply({ targetInfos: tabs });
    browserReply({ sessionId: 'wire-session' });
    pageReply(result);
}
const entries = [
    { id: 21, url: 'about:blank', userTypedURL: '', title: '', transitionType: 'typed' },
    { id: 84, url: tabs[1].url, userTypedURL: tabs[1].url, title: 'Fixture', transitionType: 'link' },
    { id: 54, url: 'https://fixture.test/next?private=secret', userTypedURL: '', title: 'Private', transitionType: 'link' },
];
for (const [action, currentIndex, entryId] of [['back', 1, 21], ['forward', 1, 54]]) {
    historySetup({ currentIndex, entries });
    pageReply({});
    browserReply({});
    const result = onConnection('history_navigation', { page_ref: explicit.page_ref, action });
    assert.deepEqual(result, { outcome: 'history_navigation_requested', page_ref: explicit.page_ref, action });
    assert.deepEqual(emitted.slice(-5).map(cmd => cmd.method), ['Target.getTargets', 'Target.attachToTarget', 'Page.getNavigationHistory', 'Page.navigateToHistoryEntry', 'Target.detachFromTarget']);
    assert.equal(emitted.at(-4).params.targetId, tabs[1].targetId);
    assert.equal(emitted.at(-3).sessionId, 'wire-session');
    assert.deepEqual(emitted.at(-2).params, { entryId });
}
historySetup({ frameTree: { frame: { id: tabs[1].targetId, loaderId: 'example-loader', url: tabs[1].url } } });
pageReply({});
browserReply({});
assert.deepEqual(onConnection('history_navigation', { page_ref: explicit.page_ref, action: 'reload' }), {
    outcome: 'history_navigation_requested', page_ref: explicit.page_ref, action: 'reload',
});
assert.equal(emitted.at(-2).method, 'Page.reload');
assert.deepEqual(emitted.at(-2).params, { loaderId: 'example-loader' });
for (const [history, outcome] of [
    [{ currentIndex: 2, entries }, 'history_boundary'],
    [{ currentIndex: 1, entries: [...entries.slice(0, 2), { ...entries[2], url: 'chrome://settings/private' }] }, 'history_navigation_rejected'],
]) {
    historySetup(history);
    browserReply({});
    assert.deepEqual(onConnection('history_navigation', { page_ref: explicit.page_ref, action: 'forward' }), { outcome, page_ref: explicit.page_ref, action: 'forward' });
    assert.deepEqual(emitted.slice(-2).map(cmd => cmd.method), ['Page.getNavigationHistory', 'Target.detachFromTarget']);
}
browserReply({ targetInfos: [{ ...tabs[1], url: 'chrome://settings' }] });
assert.deepEqual(onConnection('navigate', { page_ref: explicit.page_ref, url: tabs[1].url }), { error: 'navigation_rejected' });
assert.equal(emitted.at(-1).method, 'Target.getTargets', 'protected source tab never attaches');
assert.deepEqual(onConnection('status'), { status: 'connected' });
received.push({ id: nextId++, error: { code: -32602, message: 'private CDP diagnostics' } });
assert.deepEqual(onConnection('new_tab'), { outcome: 'tab_creation_rejected' });
assert.equal(received.length, 0);

// WebMCP uses a separate flattened page attachment and only typed CDP.
const mcpPage = { page_ref: explicit.page_ref };
const frameId = tabs[1].targetId;
const toolId = 'exact-opaque-registration-id';
const mcpFrame = { frameTree: { frame: { id: frameId, loaderId: 'mcp-loader', url: tabs[1].url } } };
const inputSchema = { type: 'object', required: ['word'], properties: { word: { type: 'string' } } };
const topTool = { frameId, toolId, name: 'echo', description: 'fixture', inputSchema, annotations: { readOnly: true } };
const event = (method, params, sessionId = 'wire-session') => received.push({ method: 'WebMCP.' + method, params, sessionId });
const catalogMethods = ['Target.getTargets', 'Target.attachToTarget', 'Page.getFrameTree', 'WebMCP.enable', 'Page.getFrameTree'];
const beforeInvalidMcp = emitted.length;
for (const args of [{...mcpPage, toolName: 'echo', input: {}}, {...mcpPage, tool_ref: elementRef, input: []},
    {...mcpPage, tool_ref: elementRef, frameId: frameId, input: {}}, {...mcpPage, tool_ref: elementRef, input: {large: 'a'.repeat(8192)}}]) {
    assert.equal(onConnection('webmcp_invoke', args).code, 'invalid_request');
}
assert.equal(onConnection('webmcp_list', {...mcpPage, frameId}).code, 'invalid_request');
assert.equal(emitted.length, beforeInvalidMcp);
function mcpCatalog(tools = [topTool]) {
    const at = emitted.length;
    historySetup(mcpFrame);
    event('toolsAdded', { tools: [ { ...topTool, name: 'wrong attachment' } ] }, 'foreign-session');
    pageReply({});
    event('toolsAdded', { tools });
    pageReply(mcpFrame);
    return at;
}
admittedMode = 'observe';
const beforeMcpFacts = factsCalls;
let mcpAt = mcpCatalog([{ ...topTool, frameId: 'wrong-frame' }, topTool]);
browserReply({});
const registry = onConnection('webmcp_list', mcpPage);
assert.equal(registry.outcome, 'listed');
assert.equal(registry.untrusted, true);
assert.equal(registry.tools.length, 1);
assert.deepEqual(registry.tools[0].inputSchema, inputSchema);
assert.deepEqual(registry.tools[0].annotations, { readOnly: true });
assert(!JSON.stringify(registry).includes(toolId));
const toolRef = registry.tools[0].tool_ref;
assert.match(toolRef, /^[a-f0-9]{32}$/);
assert.deepEqual(emitted.slice(mcpAt).map(x => x.method), [...catalogMethods, 'Target.detachFromTarget']);
assert.equal(factsCalls, beforeMcpFacts);
const mcpArg = { ...mcpPage, tool_ref: toolRef, input: { word: 'fixture' } };
admittedMode = 'interaction';
mcpAt = mcpCatalog([{ ...topTool, toolId: 're-registered-same-name' }]);
browserReply({});
assert.equal(onConnection('webmcp_invoke', mcpArg).outcome, 'stale_tool_ref');
assert.deepEqual(emitted.slice(mcpAt).map(x => x.method), [...catalogMethods, 'Target.detachFromTarget']);
mcpAt = mcpCatalog();
pageReply({ invocationId: 'exact-invocation' });
event('toolInvoked', { frameId: 'wrong-frame', toolId, invocationId: 'unrelated', input: '{}' });
event('toolResponded', { invocationId: 'exact-invocation', status: 'Completed', output: 'wrong socket session' }, 'foreign-session');
event('toolInvoked', { frameId, toolId, invocationId: 'exact-invocation', input: JSON.stringify(mcpArg.input) });
event('toolResponded', { invocationId: 'unrelated', status: 'Error' });
event('toolResponded', { invocationId: 'exact-invocation', status: 'Completed', output: { echoed: 'fixture' } });
browserReply({});
const completion = onConnection('webmcp_invoke', mcpArg);
assert.deepEqual(completion, { outcome: 'completed', ...mcpPage, tool_ref: toolRef, untrusted: true, output: { echoed: 'fixture' } });
assert.deepEqual(emitted.slice(mcpAt).map(x => x.method), [...catalogMethods, 'WebMCP.invokeTool', 'Target.detachFromTarget']);
assert.deepEqual(emitted.at(-2).params, {frameId, toolId, input: mcpArg.input});
historySetup(mcpFrame);
received.push({ id: nextId++, sessionId: 'wire-session', error: { code: -32601, message: 'synthetic unsupported' } });
browserReply({});
assert.equal(onConnection('webmcp_list', mcpPage).outcome, 'unsupported');
mcpCatalog([{ frameId, name: 'echo', description: 'old Chrome name-only registration' }]);
browserReply({});
assert.equal(onConnection('webmcp_list', mcpPage).outcome, 'unsupported');
assert.equal(received.length, 0);

// Closed parameters and bounds fail before starting transport.
const scopedBase = { page_ref: explicit.page_ref };
const scopedElement = { ...scopedBase, element_ref: snapshotElement };
const beforeInvalidScoped = emitted.length;
for (const [tool, args, code] of [
    ['close_tab', { ...scopedBase, targetId: 'explicit-tab' }, 'invalid_request'],
    ['scroll', { ...scopedBase, delta_y: 2001 }, 'invalid_scroll'],
    ['scroll', { ...scopedBase, delta_y: '10' }, 'invalid_request'],
    ['scroll', { ...scopedBase, delta_y: 1.5 }, 'invalid_request'],
    ['scroll', { ...scopedElement, delta_y: 10 }, 'invalid_request'],
    ['find', scopedBase, 'invalid_find'],
    ['find', { ...scopedBase, role: 'BUTTON' }, 'invalid_find'],
    ['find', { ...scopedBase, text: '猫'.repeat(41) }, 'invalid_find'],
    ['find', { ...scopedBase, role: null }, 'invalid_request'],
    ['set_checked', { ...scopedElement, checked: 'false' }, 'invalid_request'],
    ['select_option', { ...scopedElement, value: 'x'.repeat(513) }, 'invalid_option_value'],
    ['wait_for', { ...scopedBase, condition: 'document_ready' }, 'invalid_request'],
    ['wait_for', { ...scopedBase, timeout_ms: 1, condition: '0' }, 'invalid_request'],
    ['wait_for', { ...scopedBase, timeout_ms: 1, condition: 0 }, 'invalid_request'],
    ['wait_for', { ...scopedBase, timeout_ms: 7001, condition: 'document_ready' }, 'invalid_wait'],
    ['wait_for', { ...scopedBase, timeout_ms: 0, condition: 'document_ready' }, 'invalid_wait'],
    ['wait_for', { ...scopedBase, timeout_ms: 1, condition: 'element_visible' }, 'invalid_wait'],
    ['wait_for', { ...scopedElement, timeout_ms: 1, condition: 'document_ready' }, 'invalid_wait'],
]) assert.equal(onConnection(tool, args).code, code, tool + ': ' + JSON.stringify(args));
assert.equal(emitted.length, beforeInvalidScoped);
const activeWitness = { ...witness, params: { context: { ...witness.params.context,
    name: 'microcrab-observe-mock-5', auxData: { ...witness.params.context.auxData, frameId: tabs[1].targetId },
} } };
function scopedFixture(tool, args, value, expectedArg, awaitPromise = false) {
    historySetup({ executionContextId: 42 });
    received.push(activeWitness);
    pageReply({}); // Runtime.enable
    pageReply({}); // Runtime.disable
    pageReply({ result: { value } });
    browserReply({}); // detach
    const start = emitted.length;
    const result = onConnection(tool, args);
    const call = emitted.at(-2);
    assert.deepEqual(emitted.slice(start).map(command => command.method), scopedMethods);
    assert.equal(call.params.awaitPromise, awaitPromise);
    assert.equal(call.params.uniqueContextId, 'wire-unique');
    const body = call.params.arguments[3].value;
    assert.deepEqual(tool === 'select_option' ? Buffer.from(body, 'base64').toString('utf8') : JSON.parse(body), expectedArg);
    return [result, call];
}
const cursor = 'e'.repeat(32);
const factsBeforeReads = factsCalls;
admittedMode = 'observe';
const [found, findCall] = scopedFixture('find', { ...scopedBase, text: 'save', role: 'button', continuation: cursor }, {
    rows: [{ r: 'button', n: 'Save', ref: snapshotElement }], continuation: cursor, coverage: 'more', presentationLimited: false,
}, { text: 'save', role: 'button' });
assert.deepEqual(found.rows, [{ role: 'button', name: 'Save', ref: snapshotElement }]);
assert.equal(found.continuation, cursor);
const [waited, waitCall] = scopedFixture('wait_for', { ...scopedElement, timeout_ms: 50, condition: 'element_hidden' }, { outcome: 'timed_out' },
    { condition: 'element_hidden', timeout_ms: 50 }, true);
assert.deepEqual(waited, { outcome: 'timed_out' });
assert.equal(factsCalls, factsBeforeReads, 'read-only find/wait do not request effect admission');
admittedMode = 'interaction';
const [scrolled, scrollCall] = scopedFixture('scroll', { ...scopedBase, delta_y: -100 }, { outcome: 'scroll_requested' }, { x: 0, y: -100 });
assert.deepEqual(scrolled, { outcome: 'scroll_requested' });
const [checked, checkCall] = scopedFixture('set_checked', { ...scopedElement, checked: false }, { outcome: 'checked_set' }, false);
assert.deepEqual(checked, { outcome: 'checked_set' });
const exactOption = '\uFEFF' + '\u0000'.repeat(509); // 512 UTF-8 bytes; preserve BOM and controls literally.
const [selected, selectCall] = scopedFixture('select_option', { ...scopedElement, value: exactOption }, { outcome: 'option_selected' }, exactOption);
assert.deepEqual(selected, { outcome: 'option_selected' });
assert(findCall.params.functionDeclaration === waitCall.params.functionDeclaration && checkCall.params.functionDeclaration === selectCall.params.functionDeclaration);
{
    // Exercise the fixed probe on synthetic in-memory DOM objects. No Chrome,
    // real endpoint, or renderer trust is needed to check exact dispatch.
    let visible = true;
    let scroll;
    const doc = { URL: 'https://fixture.test', location: { protocol: 'https:' }, readyState: 'complete',
        documentElement: {}, getElementById: () => null, scrollingElement: { scrollBy: delta => { scroll = delta; } } };
    const events = [];
    const shape = { ownerDocument: doc, isConnected: true, parentElement: {}, getAttribute: () => null,
        hasAttribute: () => false, closest: () => null, matches: () => false, checkVisibility: () => visible,
        dispatchEvent: event => events.push(event.type) };
    class Input { get checked() { return this._checked; } set checked(value) { this._checked = value; } }
    class Select {}
    const input = Object.assign(new Input(), shape, { localName: 'input', type: 'checkbox', checked: true });
    const select = Object.assign(new Select(), shape, { localName: 'select', multiple: false, options: [] });
    const option = { value: exactOption, selected: false, closest: () => select, matches: () => false };
    select.options.push(option);
    const refs = new Map();
    const context = { document: doc, HTMLInputElement: Input, HTMLSelectElement: Select, performance, setTimeout, TextDecoder, atob,
        Event: class { constructor(type) { this.type = type; } },
        'microcrab-observe-mock-5': { root: doc.documentElement, url: doc.URL, refs } };
    const setRef = (node, role) => refs.set(snapshotElement, { kind: 'node', node, parent: node.parentElement, role, label: '' });
    const run = call => {
        context.args = call.params.arguments.map(arg => arg.value);
        return runInNewContext('globalThis.top = globalThis; (' + call.params.functionDeclaration + ')(...args)', context);
    };
    setRef(input, 'checkbox');
    assert.equal(run(checkCall).outcome, 'checked_set');
    assert.equal(input.checked, false);
    assert.equal(run(checkCall).outcome, 'already_checked_state');
    assert.deepEqual(events, ['input', 'change']);
    visible = false;
    assert.equal((await run(waitCall)).outcome, 'condition_met');
    visible = true;
    assert.equal((await run(waitCall)).outcome, 'timed_out');
    setRef(select, 'combobox');
    assert.equal(run(selectCall).outcome, 'option_selected');
    assert.equal(option.selected, true);
    select.options.push({ ...option });
    assert.equal(run(selectCall).error, 'not_actionable', 'reject duplicate option values');
    assert.deepEqual(events, ['input', 'change', 'input', 'change']);
    assert.equal(run(scrollCall).outcome, 'scroll_requested');
    assert.deepEqual({ ...scroll }, { left: 0, top: -100, behavior: 'instant' });
    assert.equal(run(findCall).error, 'stale_ref', 'cursor must be issued for this query and document');
}
for (const targetInfos of [[tabs[1]], [tabs[0], { ...tabs[1], url: 'chrome://settings' }], [tabs[0], { ...tabs[1], subtype: 'prerender' }]]) {
    browserReply({ targetInfos });
    assert.deepEqual(onConnection('close_tab', scopedBase), { outcome: 'tab_close_blocked', ...scopedBase });
    assert.equal(emitted.at(-1).method, 'Target.getTargets');
}
browserReply({ targetInfos: tabs });
received.push({ id: nextId++, error: { code: -32000, message: 'private CDP diagnostics' } });
assert.deepEqual(onConnection('close_tab', scopedBase), { outcome: 'tab_close_rejected', ...scopedBase });
browserReply({ targetInfos: tabs });
browserReply({ success: true });
assert.deepEqual(onConnection('close_tab', scopedBase), { outcome: 'tab_close_requested', ...scopedBase });
assert.deepEqual(emitted.at(-1), { id: nextId - 1, method: 'Target.closeTarget', params: { targetId: tabs[1].targetId } });
browserReply({ targetInfos: tabs.filter(tab => tab !== tabs[1]) });
assert.equal(onConnection('close_tab', scopedBase).code, 'stale_page');

const handlesBeforeAmbiguous = nextHandle;
historySetup({ currentIndex: 1, entries });
pageReply({});
received.push({ id: nextId++, error: { code: -32000, message: 'detach rejected' } });
assert.equal(onConnection('history_navigation', { page_ref: explicit.page_ref, action: 'back' }).code, 'outcome_unknown');
assert.equal(onConnection('status').code, 'stale_connection');
assert.equal(nextHandle, handlesBeforeAmbiguous);
assert.equal(onConnection('select_tab', { page_ref: explicit.page_ref }).code, 'stale_connection');
assert.equal(emitted.at(-1).method, 'Target.detachFromTarget');
assert.equal(received.length, 0);

// Same generation before and after a soft timeout with an exact late reply.
connect();
const recoveredHandle = nextHandle;
const beforeRecovery = settled;
residual.push({ method: 'Target.targetCreated', params: {} }, version);
remainingTransport = 2100;
softEmptyWaits = 1;
received.push({ id: 2, result: { targetInfos } });
const recovered = onConnection('list_pages');
assert.equal(recovered.kind, 1);
assert.equal(recovered.code, 'timeout');
assert.equal(settled, beforeRecovery + 1);
assert.equal(residual.length, 0);
assert.equal(nextHandle, recoveredHandle);
remainingTransport = 10_000;
received.push({ id: 3, result: { targetInfos } });
assert.equal(onConnection('list_pages').pages[0].title, targetInfos[0].title);
assert.equal(nextHandle, recoveredHandle);

// A confirmed attach/detach with a rejected JPEG must retain the same socket.
received.push({ id: 4, result: { targetInfos } });
const currentPageRef = onConnection('list_pages').pages[0].ref;
const beforeJpeg = settled;
const stagesBeforeJpeg = stagedBytes.length;
received.push(...screenshotReplies(5, framedJpeg(114_689)));
assert.equal(onConnection('screenshot', { ...destination, page_ref: currentPageRef }).code, 'screenshot_limit');
assert.equal(stagedBytes.length, stagesBeforeJpeg);
assert.equal(settled, beforeJpeg + 1);
received.push({ id: 9, result: { targetInfos: [] } });
assert.equal(onConnection('screenshot', { ...destination, page_ref: currentPageRef }).code, 'stale_page');
assert.equal(settled, beforeJpeg + 2);
received.push({ id: 10, result: { targetInfos } });
assert.equal(onConnection('list_pages').pages[0].ref, currentPageRef);
assert.equal(nextHandle, recoveredHandle);

// 64 small asynchronous events before a valid reply are not a transport failure.
const beforeBurst = checkpoints.length;
received.push(...Array(64).fill({ method: 'fixture.noise', params: { opaque: 'private fixture' } }),
    { id: 11, result: { targetInfos } });
assert.equal(onConnection('list_pages').pages[0].ref, currentPageRef);
assert.equal(nextHandle, recoveredHandle);
assert.deepEqual(checkpoints.slice(beforeBurst), debugObservation ? [
    [1, 0, 1, 0], // Target.getTargets, send, exchange 1, not confirmed
    [1, 1, 1, 0], // receive the matching reply, no per-packet checkpoint
    [1, 2, 1, 1], // exact reply envelope confirmed
] : []);

// No exact reply before cleanup budget: do not reuse or dispatch the next call.
remainingTransport = 2100;
softEmptyWaits = 8;
const beforeLostReply = settled;
assert.equal(onConnection('list_pages').code, 'timeout');
assert.equal(settled, beforeLostReply);
const sentBeforeClosed = emitted.length;
assert.equal(onConnection('list_pages').code, 'stale_connection');
assert.equal(emitted.length, sentBeforeClosed);
assert.equal(nextHandle, recoveredHandle);

assert.deepEqual(drive(connectionJob), { state: '', delay: 0n, finished: 1 }, 'fenced connection stops the receiver');

remainingTransport = 10_000;
softEmptyWaits = 0;
const cancelJob = connect();
residual.push({ method: 'fixture.unreadOnCancel', params: {} });
cancelConnection(cancelJob);
assert.equal(residual.length, 1, 'cancellation takes priority over pending input');
residual.length = 0; // Discard bytes owned by the retired synthetic socket.
assert.equal(onConnection('status').code, 'stale_connection');
assert.deepEqual(drive(cancelJob), { state: '', delay: 0n, finished: 1 });

const runtimeCancelledJob = connect();
active = false; // Runtime may finish cleanup without reacquiring the guest store.
const beforeHandoff = calls.length;
const resumedJob = connect();
assert.notEqual(resumedJob.state, runtimeCancelledJob.state);
assert.deepEqual(calls.slice(beforeHandoff), ['ws-open', 'ws-send', 'ws-receive'], 'new admit does not operate on the retired scope');
assert.equal(onConnection('status', {}, runtimeCancelledJob.state).code, 'stale_connection');
cancelConnection(resumedJob);

rejectAttach = true;
received.push(version);
const rejectedJob = invoke('connect', { endpoint: url });
assert.equal(rejectedJob.code, 'connection_job_failed');
assert(!rejectedJob.message.includes('fixture-only'));
assert(jobs.get(nextBuffer).ownedDropped, 'failed handoff drops its owned buffer');
assert(!active, 'failed handoff retires the opened socket');
rejectAttach = false;
const finalJob = connect();
assert.notEqual(finalJob.state, cancelJob.state, 'reconnect is explicit and starts a new generation');

// Page-scoped network observation over the same synthetic socket. Drive may
// publish safe references and counters; only an admitted tool fetches a body.
nextId = 2;
browserReply({ targetInfos });
const networkPage = onConnection('list_pages').pages[0].ref;
const prefix = 'https://fixture.test/api/';
const bodyPrefix = `${prefix}body/`;
const privateUrl = `${bodyPrefix}response?fixture=retained`;
const bodyText = 'synthetic response abc';
const networkEvent = (method, requestId, sessionId, response) => ({
    method: `Network.${method}`, sessionId, params: { requestId, ...(response === undefined ? {} : { response }) },
});
function networkResponse(requestId, responseUrl, sessionId = 'wire-session') {
    residual.push(networkEvent('responseReceived', requestId, sessionId, { url: responseUrl, mimeType: 'application/json', status: 200 }),
        networkEvent('loadingFinished', requestId, sessionId));
}
networkResponse('disabled-request', privateUrl);
assert.equal(drive(finalJob).finished, 0);
assert.deepEqual(finalJob.published, [], 'network observation is off by default');
const firstNetworkCommand = emitted.length;
browserReply({ targetInfos });
browserReply({ sessionId: 'wire-session' });
pageReply({});
const settings = { page_ref: networkPage, network_enabled: true, url_prefix: prefix, body_url_prefix: bodyPrefix };
assert.deepEqual(onConnection('configure_connection', settings), { network: 'enabled', page_ref: networkPage });
assert.deepEqual(emitted.slice(firstNetworkCommand).map(({ method }) => method), ['Target.getTargets', 'Target.attachToTarget', 'Network.enable']);
networkResponse('wrong-page', privateUrl, 'foreign-session');
networkResponse('wrong-filter', 'https://fixture.test/ignored');
networkResponse('exact-request', privateUrl);
assert.equal(drive(finalJob).finished, 0);
assert.equal(finalJob.published.length, 1, 'only the exact page and matching filter publish');
assert(!JSON.stringify(finalJob.published).includes(privateUrl));
assert(!JSON.stringify(finalJob.published).includes('exact-request'));
const summary = finalJob.published[0];
assert.match(summary.record_id, /^[1-9]\d*$/);
assert.deepEqual(summary, { kind: 'network', page_ref: networkPage, record_id: summary.record_id, outcome: 'request_finished', http_status: 200 });
const detailArgs = { page_ref: networkPage, record_id: summary.record_id };
const beforeMetadata = emitted.length;
const wrongPage = onConnection('read_network_detail', { ...detailArgs, page_ref: pageRef, include_body: true });
assert.equal(wrongPage.code, 'record_expired', 'a record cannot be read against a different page');
assert.equal(wrongPage.url, undefined);
assert.equal(wrongPage.body, undefined);
assert.deepEqual(onConnection('read_network_detail', detailArgs), { ...detailArgs, url: privateUrl, body_status: 'fetchable' });
assert.equal(emitted.length, beforeMetadata, 'metadata does not trigger a protocol request');
pageReply({ body: bodyText, base64Encoded: false });
const detail = onConnection('read_network_detail', { ...detailArgs, include_body: true });
assert.deepEqual(detail, { ...detailArgs, url: privateUrl, body_status: 'text', body: bodyText });
assert.deepEqual(emitted.at(-1), { id: nextId - 1, sessionId: 'wire-session', method: 'Network.getResponseBody', params: { requestId: 'exact-request' } });
assert(!JSON.stringify(finalJob.published).includes(bodyText));
networkResponse('other-matched-url', `${prefix}metadata-only`);
networkResponse('oversized-body', `${bodyPrefix}oversized`);
assert.equal(drive(finalJob).finished, 0);
assert.equal(finalJob.published.length, 3);
const metadataOnly = { page_ref: networkPage, record_id: finalJob.published[1].record_id };
const beforeUnrequested = emitted.length;
assert.deepEqual(onConnection('read_network_detail', { ...metadataOnly, include_body: true }), {
    ...metadataOnly, url: `${prefix}metadata-only`, body_status: 'not_requested',
});
assert.equal(emitted.length, beforeUnrequested, 'body filter cannot be broadened by a detail read');
const oversizedBody = { page_ref: networkPage, record_id: finalJob.published[2].record_id };
pageReply({ body: 'x'.repeat(16 * 1024 + 1), base64Encoded: false });
assert.deepEqual(onConnection('read_network_detail', { ...oversizedBody, include_body: true }), {
    ...oversizedBody, url: `${bodyPrefix}oversized`, body_status: 'too_large',
});
browserReply({});
assert.deepEqual(onConnection('configure_connection', { page_ref: networkPage, network_enabled: false }), { network: 'disabled', page_ref: networkPage });
assert.equal(emitted.at(-1).method, 'Target.detachFromTarget');
const expired = onConnection('read_network_detail', detailArgs);
assert.equal(expired.code, 'record_expired', 'disabling observation invalidates retained details');
assert.equal(expired.url, undefined);
assert.equal(expired.body, undefined);
browserReply({ targetInfos });
browserReply({ sessionId: 'wire-session' });
pageReply({});
assert.equal(onConnection('configure_connection', settings).network, 'enabled');
networkResponse('later-request', `${prefix}after-enable`);
assert.equal(drive(finalJob).finished, 0);
assert.equal(finalJob.published.length, 4);
assert.notEqual(finalJob.published.at(-1).record_id, summary.record_id, 're-enabling does not alias an earlier record');
assert.equal(onConnection('read_network_detail', detailArgs).code, 'record_expired');
cancelConnection(finalJob);

// execute_js uses a fresh exact attachment, top document and globally unique
// context. Test both worlds, loss/ambiguity, and sanitized bounded receipts.
const jsJob = connect();
nextId = 2;
browserReply({ targetInfos });
const jsPage = onConnection('list_pages').pages[0].ref;
const expression = 'document.title + " \\u{1F980}"';
const jsArgs = { page_ref: jsPage, expression };
const invalidBegin = emitted.length;
for (const extra of [{ expression: '' }, { expression: '🦀'.repeat(513) }, { expression: false }, { world: 'page' },
    { world: null }, { timeout_ms: 0 }, { timeout_ms: 2001 }, { timeout_ms: '1' }, { timeout_ms: null }, { frameId: 'child' }]) {
    assert.equal(onConnection('execute_js', { ...jsArgs, ...extra }).code, 'invalid_request');
}
assert.equal(emitted.length, invalidBegin, 'invalid JavaScript arguments never reach CDP');
const jsFrame = { id: 'wire-target', loaderId: 'js-loader', url: 'https://fixture.test' };
function jsWitness(world, more = {}, sessionId = 'wire-session') {
    return { method: 'Runtime.executionContextCreated', sessionId, params: { context: {
        id: 42, name: world === 'isolated' ? `microcrab-execute-${jsJob.state}` : '', uniqueId: 'js-unique',
        auxData: { frameId: jsFrame.id, type: world === 'main' ? 'default' : world, isDefault: world === 'main' }, ...more,
    } } };
}
function jsSetup(world, { witnesses = [jsWitness(world)], followupFrame = jsFrame } = {}) {
    browserReply({ targetInfos });
    browserReply({ sessionId: 'wire-session' });
    pageReply({ frameTree: { frame: jsFrame } });
    if (world === 'isolated') pageReply({ executionContextId: 42 });
    received.push(...witnesses);
    pageReply({}); // Runtime.enable
    pageReply({}); // Runtime.disable
    pageReply({ frameTree: { frame: followupFrame } });
}
for (const [args, world, timeout, value] of [[jsArgs, 'isolated', 1000, { text: 'fixture 🦀' }],
    [{ ...jsArgs, world: 'main', timeout_ms: 25 }, 'main', 25, null]]) {
    const begin = emitted.length;
    jsSetup(world, { witnesses: [
        jsWitness(world, { uniqueId: 'cross-session' }, 'other-session'),
        jsWitness(world, { uniqueId: 'iframe-context', auxData: { frameId: 'child', isDefault: true, type: 'default' } }),
        jsWitness(world === 'main' ? 'isolated' : 'main', { uniqueId: 'wrong-world' }),
        jsWitness(world),
    ] });
    pageReply({ result: { type: 'object', value } });
    browserReply({});
    assert.deepEqual(onConnection('execute_js', args), { outcome: 'evaluated', result: value });
    assert.deepEqual(emitted.slice(begin).map(cmd => cmd.method), ['Target.getTargets', 'Target.attachToTarget', 'Page.getFrameTree',
        ...(world === 'isolated' ? ['Page.createIsolatedWorld'] : []), 'Runtime.enable', 'Runtime.disable', 'Page.getFrameTree',
        'Runtime.evaluate', 'Target.detachFromTarget']);
    if (world === 'isolated') assert.deepEqual(emitted[begin + 3].params, { frameId: jsFrame.id, worldName: `microcrab-execute-${jsJob.state}` });
    assert.equal(emitted.at(-2).sessionId, 'wire-session');
    assert.deepEqual(emitted.at(-2).params, { expression, uniqueContextId: 'js-unique', timeout, returnByValue: true,
        generatePreview: false, includeCommandLineAPI: false, awaitPromise: false, allowUnsafeEvalBlockedByCSP: false, disableBreaks: true, silent: true });
}
for (const config of [{ witnesses: [] }, { followupFrame: { ...jsFrame, loaderId: 'new-document' } }]) {
    const begin = emitted.length;
    jsSetup('main', config);
    browserReply({});
    assert.deepEqual(onConnection('execute_js', { ...jsArgs, world: 'main' }), { outcome: 'context_unavailable' });
    assert(!emitted.slice(begin).some(cmd => cmd.method === 'Runtime.evaluate'));
}
browserReply({ targetInfos: [{ ...targetInfos[0], url: 'chrome://settings' }] });
assert.deepEqual(onConnection('execute_js', jsArgs), { outcome: 'page_not_allowed' });
assert.equal(emitted.at(-1).method, 'Target.getTargets', 'protected targets never attach');
for (const [result, expected] of [
    [{ result: { type: 'undefined' } }, { outcome: 'undefined' }],
    [{ result: { type: 'number', unserializableValue: 'NaN' } }, { outcome: 'result_unavailable' }],
    [{ result: { type: 'string', value: 'a'.repeat(8193) } }, { outcome: 'evaluated', result: 'a'.repeat(8193) }],
    [{ result: { type: 'string', value: 'a'.repeat(16000) } }, { outcome: 'evaluated', result: 'a'.repeat(16000) }],
    [{ result: { type: 'string', value: 'a'.repeat(49153) } }, { outcome: 'output_limit', max_bytes: 49152 }],
    [{ result: { type: 'object' }, exceptionDetails: { text: 'private exception source' } }, { outcome: 'script_exception' }],
    [{ result: { type: 'object' }, exceptionDetails: { text: 'private exception source', lineNumber: 0, columnNumber: 24, exception: { className: 'SyntaxError', description: 'private' } } }, { outcome: 'script_exception', exception_name: 'SyntaxError', line: 0, column: 24 }],
]) {
    jsSetup('isolated');
    pageReply(result);
    browserReply({});
    assert.deepEqual(onConnection('execute_js', { ...jsArgs, world: 'isolated' }), expected);
}
jsSetup('isolated');
received.push({ id: nextId++, sessionId: 'wire-session', error: { code: -32000, message: 'Execution was terminated' } });
browserReply({});
assert.deepEqual(onConnection('execute_js', jsArgs), { outcome: 'execution_timed_out' });
jsSetup('isolated');
received.push({ id: nextId++, sessionId: 'wrong-session', result: { result: { type: 'undefined' } } });
const sentBeforeUnknown = emitted.length;
assert.equal(onConnection('execute_js', jsArgs).code, 'outcome_unknown');
assert.equal(emitted.slice(sentBeforeUnknown).filter(cmd => cmd.method === 'Runtime.evaluate').length, 1);
assert.equal(onConnection('execute_js', jsArgs).code, 'stale_connection');
assert.equal(emitted.at(-1).method, 'Runtime.evaluate', 'unknown effect never resubmits or implicitly reconnects');
assert(!active);
assert(observations.some(([severity, code]) => severity >= 2 && code !== 0), 'bounded failure breadcrumbs are available in both profiles');
assert.equal(checkpoints.length > 0, debugObservation, 'routine checkpoints are compiled in only for Debug');
console.log('Browser wasm32 wire, catalog, and mock observation checks passed');
