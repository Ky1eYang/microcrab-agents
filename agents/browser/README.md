# MicroCrab Browser Agent 0.5.1

The registered Browser guest uses the selected Project's admitted native Bridge.
`observe` does not modify Chrome. `interaction` adds `click`, `type_text`,
`navigate`, `press_key`, `new_tab`, `select_tab`, `history_navigation`,
`close_tab`, `scroll`, `set_checked`, `select_option`, and `webmcp_invoke`.
In `observe`, `connect`, `screenshot`, `configure_connection`, and
`read_network_detail` default to Allow alongside the other observation tools;
interaction-only tools remain denied. In `interaction`, network observation
settings/detail, `webmcp_invoke`, and `execute_js` in the main world default to
Ask; isolated `execute_js` defaults to Allow. Configured tool
policy can override these defaults. Even an explicit Allow cannot bypass the guest's check for the
Runtime's typed, invocation-bound `interaction` admission. Missing mode facts
fail closed. The Session facts import is an existing Runtime interface, not an
extra Host capability or component consent. A Host without `web_transport`
receives `unsupported` without a transport operation.

## Build and verify

From the repository root, using Zig 0.13.0 and wasm-tools 1.263.0:

```sh
zig build test-browser test-wasm-browser
zig build check-vendored-component-browser
zig build check-component-browser -Dcore=/absolute/path/to/microcrab-core
zig build component-browser -Dcore=/absolute/path/to/microcrab-core
```

In `agents/browser`, use the same commands without the `-browser` suffix. The
last command emits `browser.component.wasm` under the Zig output prefix; it
neither selects nor installs the guest. Select the exact component through the
shared Server catalog. The vendored check proves component shape; the canonical
check also compares the Host, Agent and Session WIT mirrors against the selected
Core checkout. The native and Wasm tests use synthetic fixtures; they do not
establish live browser compatibility.

For isolated diagnostics, pass `-Dbrowser-debug=true` to the same build and
use a separate `--prefix`. Debug adds the typed `microcrab:session/browser-observation@0.2.3` checkpoints for command send, awaiting an exact reply, and envelope confirmation. Release keeps the `microcrab:session/observation@0.2.2` failure lane without importing the Debug companion. Diagnostics do not enable raw CDP logging, extra permissions, or override Runtime budgets. The deployable diagnostic candidate uses optimized WASM (`ReleaseFast`) with DEBUG checkpoints. Add `-Dbrowser-unoptimized=true` for literal Zig `Debug`; that build may exhaust the default Runtime fuel even during catalog loading. Do not install diagnostic bytes as the default guest.

## Protocol evidence

The upstream [Chrome DevTools Protocol specification](https://chromedevtools.github.io/devtools-protocol/)
anchors the implementation. In particular, see [Browser](https://chromedevtools.github.io/devtools-protocol/#/Browser),
[Target](https://chromedevtools.github.io/devtools-protocol/#/Target),
[Page](https://chromedevtools.github.io/devtools-protocol/#/Page), and
[Runtime](https://chromedevtools.github.io/devtools-protocol/#/Runtime). Typed
scoped DOM tools run only the guest's fixed code through an attested isolated
world; there is no model-facing arbitrary evaluation tool. The experimental
[WebMCP domain](https://chromedevtools.github.io/devtools-protocol/#/WebMCP)
and its [canonical PDL](https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/pdl/domains/WebMCP.pdl)
define registration/loss events, exact registered `toolId`, invocation receipts
and terminal events. Tip-of-tree documentation is not proof that a given Chrome
build or profile supports WebMCP. Unsupported versions fail without a name-based
or JavaScript fallback.

The Bridge reassembles WebSocket text messages without parsing CDP. The guest
classifies the top-level JSON envelope, checks the exact outstanding `id` and
flat `sessionId`, and materializes only matching replies and events required by
the current command. Raw bytes/messages are bounded separately from materialized
JSON; skipping a payload does not replenish raw allowances.

## Tools and limits

- `connect(endpoint)` uses only the explicit address. A bare `host:port`
  (including `[IPv6]:port`) requests `http://host:port/json/version`.
  `http://127.0.0.1:9222` and `https://browser.example/` also append the standard
  path on the same authority. Explicit non-root or query-bearing discovery URLs
  are preserved byte-for-byte. A direct `ws://127.0.0.1:9222/devtools/browser/example`
  or `wss://browser.example/devtools/browser/example` is used unchanged.
  Discovery must provide the same host and effective port and cannot downgrade
  TLS. The guest verifies a browser-level response. Runtime independently
  enforces admission, scope, deadline and endpoint policy. The first Buffered
  output reports `connect_id`; it is distinct from the execution handle used
  for Job actions. Every later Browser tool takes the exact `connect_id`.
  The Host reads the WebSocket and the Guest drains it in Runtime-driven
  steps between commands. Use `job.cancel` to disconnect, observe terminal
  cleanup, then `job.release`. Open the next connection explicitly.
- `configure_connection` optionally enables network observation for one page
  and literal HTTP(S) URL prefix; it is off by default. Set a body URL prefix
  only when bounded text response bodies are needed. Both this operation and
  `read_network_detail` default to Allow in observe mode and Ask in interaction mode. `job.read` shows summaries
  and loss markers. It does not return full URLs or bodies. Read the details
  explicitly by page and record ID; the content may be sensitive or untrusted.
  Capture does not retain request bodies, headers, or binary bodies. Details
  expire on eviction, disable, or connection loss.
- `execute_js` evaluates one expression on the specified ordinary page's top
  frame in interaction mode. `expression` is limited to 2,048 UTF-8 bytes;
  `timeout_ms` is 1–2,000 ms (default 1,000). Use `world: isolated` (default)
  for DOM access without page-script globals, or `world: main` when access to
  those globals is necessary. Both can cause page effects. The tool does not
  await Promises or grant Node, OS, or additional Host access. The page's
  ordinary web APIs remain available; a synchronous timeout does not roll back
  changes or prevent already scheduled asynchronous effects.
- `status` reports the current connection state without sending a browser
  command or reconnecting. `list_pages` projects only `page` targets and
  returns connection-scoped page references. `snapshot(page_ref, region_ref?)`
  revalidates the page and reads a bounded semantic projection using fixed
  internal logic in an isolated browser world. It is not a full accessibility
  tree. Use a returned region reference to expand a relevant region or continue
  a bounded read. Page text is untrusted data, not instructions.
- `click(page_ref, element_ref)` sends a synthetic click. `type_text(page_ref,
  element_ref, text)` replaces text in a supported editable element with DOM
  input events; it does not explicitly submit the form. Sites may ignore or
  react differently to synthetic events. `navigate(page_ref, url)` requests
  same-tab navigation to an explicit HTTP(S) URL. Stale references must be
  obtained again from a new observation, not guessed. An uncertain effect is
  never replayed. An unavailable connection requires explicit `connect`.
- `new_tab(url?)` requests one new tab, defaulting to `about:blank` only when
  `url` is omitted. An explicit URL must be HTTP(S), at most 4096 bytes, and
  contain no credentials. Chrome chooses tab placement; no new window or
  browser context is requested. `tab_created` returns its `page_ref`, not a
  page-load guarantee.
- `select_tab(page_ref)` revalidates and requests Chrome activation of that
  exact page, returning `tab_activation_requested` rather than a focus
  guarantee. It does not set an implicit target for any other tool. Use each
  tool's explicit `page_ref`.
- `history_navigation(page_ref, action)` requests an ordinary `reload`, `back`
  or `forward` on the exact page. It allows only HTTP(S) and `about:blank`
  destinations. Back/forward select a single adjacent history entry without
  skipping blocked entries or exposing history content. `history_boundary`
  means no adjacent entry exists; `history_navigation_rejected` means the
  action was blocked or rejected. `history_navigation_requested` confirms
  command acceptance and debugger detach, not page-load completion. The
  Browser never implicitly reconnects or retries an uncertain effect; observe
  the connection and pages before deciding on another operation.
- `close_tab(page_ref)` requests [Target.closeTarget](https://chromedevtools.github.io/devtools-protocol/#/Target/method-closeTarget)
  for the exact ordinary tab. It rejects protected targets and refuses when
  fewer than two ordinary page targets are observed. This check does not
  prevent a user concurrently closing other tabs; no Browser.close is sent.
- `scroll(page_ref, delta_y, delta_x?)` scrolls the top-level document by at
  most 2,000 CSS pixels per axis and reports a request, not a guaranteed
  offset. No implicit focus, mouse coordinates, iframe, or OS input.
- `find(page_ref, text?, role?, continuation?)` matches text and/or role in the
  bounded light-DOM projection; if both are supplied, both must match. A
  continuation requires the same query and live document. Coverage is not a
  complete accessibility-tree or hidden/shadow/iframe guarantee.
- `set_checked(page_ref, element_ref, checked)` controls a native checkbox;
  `select_option(page_ref, element_ref, value)` selects an exact value on a
  supported native select. Both revalidate the current element and report a
  confirmed or unconfirmed state change; no JS snippets are accepted.
- `wait_for(page_ref, timeout_ms, condition, element_ref?)` requires a 1–7,000 ms
  timeout. Conditions are `document_ready`, `element_visible`, and
  `element_hidden`; the latter two require an exact element reference. The
  guest uses bounded isolated-world polling via
  [Runtime.callFunctionOn](https://chromedevtools.github.io/devtools-protocol/#/Runtime/method-callFunctionOn).
  A condition timeout is distinct from a transport/caller deadline.
- `webmcp_list(page_ref)` lists bounded top-frame registrations. Use the opaque
  `tool_ref` from that result in `webmcp_invoke(page_ref, tool_ref, input)`.
  Registrations, schemas, annotation hints and output are untrusted page data.
  A missing/legacy registration without a stable CDP ID is unsupported. An
  invocation ACK or cancellation request does not prove any terminal outcome;
  do not replay unknown results.
- `press_key(page_ref, element_ref, key, modifiers?)` dispatches synthetic
  `keydown` and `keyup` to a current element without changing focus. Use one
  printable ASCII character (including a literal space) or a supported named
  key such as `Enter`, `Escape` or `ArrowDown`. Optional modifiers are distinct
  `Control`, `Alt`, `Shift`, and `Meta` flags. This does not insert text or
  invoke browser/OS shortcuts; the page may ignore the events. If the target
  moves or disappears after keydown, do not assume keyup ran or replay the call.
- `screenshot(page_ref, variable, clip?, scale?, quality?)` captures a JPEG into
  one new private ephemeral Session Bytes variable. With no framing options it
  uses the original viewport capture. JPEG `quality` is an integer from `0` to
  `100` (default `55`), and changing it alone preserves the original framing.
  `clip` is `{x, y, width, height}` in CSS pixels relative to the top left of the
  current **visual viewport**, including on a scrolled page. The whole clip must
  fit inside the viewport. `scale` is an output multiplier from `0.1` to `1`
  (default `1`); it applies to native device-pixel dimensions, not CSS pixel
  dimensions. For example, a 320×240 CSS clip at `0.5` gives 160×120 at DPR 1
  and 320×240 at DPR 2. The Browser guest sends no resize or emulation commands
  and does not take full-page screenshots. Framing requires Chrome to report
  valid viewport geometry, 100% browser zoom and no pinch zoom. A framed output
  must be at least one scaled CSS pixel per side and at most 16,777,216 scaled
  square CSS pixels, before device scaling.
- Screenshot metadata includes `image_url` for an explicit `view_image` call;
  the tool does not write a workspace file or put pixels in its response. The
  existing 256 KiB wire-message limit and 112 KiB decoded JPEG limit are unchanged.
  Neither failure saves an image or retries automatically. For `screenshot_limit`,
  request a smaller clip, lower scale or lower quality; check status and reconnect
  explicitly if closed. `screenshot_wire_limit` means the reply exceeded the
  transport limit and requires an explicit reconnect before another capture.
- Wire, decode, projection and cleanup limits are separate. Effective route
  limits can be lower than guest limits. The guest does not expose raw protocol
  bodies, debugger session IDs, or transport handles, or persist them in
  Session State.

There is no browser or profile lifecycle tool, arbitrary JavaScript evaluation,
raw CDP, workspace screenshot output, ambient authentication, or generic
networking tool.
