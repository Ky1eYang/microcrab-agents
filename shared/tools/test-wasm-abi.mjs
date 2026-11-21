// Test only linear memory and the core realloc export, not the Coding world.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const module = new WebAssembly.Module(readFileSync(process.argv[2]));
assert.deepEqual(WebAssembly.Module.imports(module), []);
assert.deepEqual(
    WebAssembly.Module.exports(module).map(({ name }) => name).sort(),
    ['cabi_realloc', 'memory'],
);
const { memory, cabi_realloc: realloc } = new WebAssembly.Instance(module).exports;
assert.equal(realloc(0, 0, 8, 0), 8);
const old = realloc(8, 0, 8, 4);
assert.notEqual(old, 0);
assert.equal(old % 8, 0);
new Uint8Array(memory.buffer, old, 4).set([1, 2, 3, 4]);
const grown = realloc(old, 4, 8, 131072);
assert.notEqual(grown, 0);
assert.equal(grown % 8, 0);
assert.deepEqual([...new Uint8Array(memory.buffer, grown, 4)], [1, 2, 3, 4]);
const shrunk = realloc(grown, 131072, 8, 2);
assert.deepEqual([...new Uint8Array(memory.buffer, shrunk, 2)], [1, 2]);
assert.equal(realloc(shrunk, 2, 8, 0), 8);
assert.throws(() => realloc(0, 0, 3, 1), WebAssembly.RuntimeError);
assert.throws(() => realloc(0, 0, 8, -1), WebAssembly.RuntimeError);
console.log('Freestanding canonical ABI memory checks passed.');
