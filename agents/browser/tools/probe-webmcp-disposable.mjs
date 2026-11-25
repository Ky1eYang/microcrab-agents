// Run only against a fresh Chrome process and local disposable HTML.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, realpath, rm } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const fixture = `<!doctype html><title>Disposable WebMCP fixture</title><script>
  const context = document.modelContext ?? navigator.modelContext;
  if (context) context.registerTool({
    name: 'echo', description: 'Echo a test-only string',
    inputSchema: {type: 'object', properties: {word: {type: 'string'}}, required: ['word']},
    execute: ({word}) => ({word})
  });
</script>`;
const profile = await mkdtemp(join(tmpdir(), 'microcrab-webmcp-chrome-'));
const server = createServer((_request, response) => {
  response.setHeader('Content-Type', 'text/html');
  response.end(fixture);
});
let chrome;
let ws;
try {
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const url = `http://127.0.0.1:${server.address().port}/`;
  chrome = spawn(process.env.CHROME_BIN ?? 'google-chrome', [
    `--user-data-dir=${profile}`, '--headless', '--remote-debugging-address=127.0.0.1',
    '--remote-debugging-port=0', '--no-first-run', '--no-default-browser-check',
    '--disable-background-networking', '--enable-features=WebMCP', url,
  ], { stdio: ['ignore', 'ignore', 'pipe'] });
  const wsUrl = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('disposable Chrome did not expose DevTools')), 8000);
    chrome.once('error', reject);
    chrome.once('exit', (code) => reject(new Error(`disposable Chrome exited: ${code}`)));
    let seen = '';
    chrome.stderr.on('data', chunk => {
      seen = (seen + chunk).slice(-4096);
      const match = seen.match(/DevTools listening on (ws:\/\/127\.0\.0\.1:\d+\/devtools\/browser\/[^\s]+)/);
      if (match) { clearTimeout(timer); resolve(match[1]); }
    });
  });
  ws = new WebSocket(wsUrl);
  await once(ws, 'open');
  let id = 0;
  const inbox = [];
  ws.addEventListener('message', e => inbox.push(JSON.parse(e.data)));
  async function take(predicate) {
    const deadline = Date.now() + 3000;
    while (Date.now() < deadline) {
      const i = inbox.findIndex(predicate);
      if (i >= 0) return inbox.splice(i, 1)[0];
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    throw new Error('no matching disposable CDP frame');
  }
  async function command(method, params, sessionId) {
    const commandId = ++id;
    ws.send(JSON.stringify({id: commandId, method, params, sessionId}));
    return take(x => x.id === commandId);
  }
  const version = (await command('Browser.getVersion')).result.product;
  let tab;
  const deadline = Date.now() + 4000;
  do {
    tab = (await command('Target.getTargets')).result.targetInfos.find(t => t.type === 'page' && t.url === url);
    if (!tab) await new Promise(resolve => setTimeout(resolve, 20));
  } while (!tab && Date.now() < deadline);
  assert.ok(tab);
  const {sessionId} = (await command('Target.attachToTarget', {targetId: tab.targetId, flatten: true})).result;
  const enable = await command('WebMCP.enable', undefined, sessionId);
  if (enable.error) {
    assert.equal(enable.error.code, -32601);
    console.log(`${version}: typed unsupported (WebMCP.enable absent)`);
  } else {
    const root = (await command('Page.getFrameTree', undefined, sessionId)).result.frameTree.frame.id;
    const registrations = inbox.filter(e => e.sessionId === sessionId && e.method === 'WebMCP.toolsAdded').flatMap(e => e.params.tools);
    const tool = registrations.find(t => t.frameId === root && t.name === 'echo');
    if (!tool) console.log(`${version}: domain enabled, disposable page exposed no WebMCP registration`);
    else if (!tool.toolId) console.log(`${version}: typed unsupported (legacy name-only registration)`);
    else {
      assert.equal(tool.inputSchema.properties.word.type, 'string');
      const invoke = await command('WebMCP.invokeTool', {frameId: root, toolId: tool.toolId, input: {word: 'local-fixture'}}, sessionId);
      assert.ok(invoke.result?.invocationId, 'no exact-ID invocation ACK');
      const invocationId = invoke.result.invocationId;
      const start = await take(e => e.sessionId === sessionId && e.method === 'WebMCP.toolInvoked' && e.params.invocationId === invocationId);
      assert.equal(start.params.frameId, root);
      assert.equal(start.params.toolId, tool.toolId);
      const terminal = await take(e => e.sessionId === sessionId && e.method === 'WebMCP.toolResponded' && e.params.invocationId === invocationId);
      assert.equal(terminal.params.status, 'Completed');
      assert.deepEqual(terminal.params.output, {word: 'local-fixture'});
      console.log(`${version}: exact-ID invocation start and terminal witnessed`);
    }
  }
  assert.ok((await command('Target.detachFromTarget', {sessionId})).result);
  assert.ok((await command('Browser.close')).result);
} finally {
  ws?.close();
  if (chrome && chrome.pid && chrome.exitCode === null && chrome.signalCode === null) {
    const exit = once(chrome, 'exit');
    chrome.kill('SIGTERM');
    const force = setTimeout(() => chrome.kill('SIGKILL'), 1500);
    await exit;
    clearTimeout(force);
  }
  server.close();
  // Only remove the exact temp directory minted above; never use a live profile.
  assert.equal(await realpath(profile), profile);
  await rm(profile, {recursive: true, maxRetries: 6, retryDelay: 100});
}
