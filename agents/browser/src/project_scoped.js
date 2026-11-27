  // This suffix is joined to the fixed common isolated-world probe in Zig.
  const args = op === 'select_option'
    ? new TextDecoder('utf-8', {fatal:true, ignoreBOM:true}).decode(Uint8Array.from(atob(input), c => c.charCodeAt(0)))
    : JSON.parse(input);
  function same(entry) {
    const el = entry.node;
    return live(el) && el.parentElement === entry.parent && role(el) === entry.role && label(el) === entry.label;
  }
  function visible(el) {
    return live(el) && !el.closest('[hidden],[aria-hidden="true"]') &&
      el.checkVisibility({checkOpacity:true, checkVisibilityCSS:true});
  }
  if (op === 'wait_for') {
    const url = doc.URL;
    const entry = ref && current() ? find(ref) : null;
    if (ref && (!entry || entry.kind !== 'node' || !same(entry))) return {error:'stale_ref'};
    return (async () => {
      const deadline = performance.now() + args.timeout_ms;
      // At most 71 samples; renderer scheduling can delay timers, so the
      // existing Host deadline remains the outer cancellation/cleanup bound.
      for (let sample=0; sample<=70; ++sample) {
        if (doc.URL !== url || doc.documentElement !== root || (entry && globalThis[key] !== state)) return {error:'stale_ref'};
        const remaining = deadline - performance.now();
        if (sample > 0 && remaining <= 0) break;
        if (entry && live(entry.node) && !same(entry)) return {error:'stale_ref'};
        const ready = args.condition === 'document_ready' ? doc.readyState === 'complete' :
          args.condition === 'element_visible' ? visible(entry.node) : !visible(entry.node);
        if (ready) return {outcome:'condition_met'};
        if (remaining <= 0 || sample === 70) break;
        await new Promise(resolve => setTimeout(resolve, Math.min(100, remaining)));
      }
      return {outcome:'timed_out'};
    })();
  }
  if (op === 'scroll') {
    const target = doc.scrollingElement;
    if (!target) return {error:'not_actionable', detail: 'document has no scrollingElement'};
    target.scrollBy({left:args.x, top:args.y, behavior:'instant'});
    return {outcome:'scroll_requested'};
  }
  if (!current()) return {error:'stale_ref', detail: `no active snapshot for current URL (${doc.URL}); run snapshot again`};
  if (op === 'find') {
    const entry = ref ? find(ref) : null;
    if (ref && (!entry || entry.kind !== 'find' || entry.input !== input ||
        !live(entry.node) || entry.node.parentNode !== entry.parent)) return {error:'stale_ref'};
    const query = args.text?.toLowerCase();
    const matches = (r,n) => (!args.role || r === args.role) && (!query || n.toLowerCase().includes(query));
    const rows = [];
    let node = entry?.node || root;
    let steps = 0;
    let depthLimited = false;
    let presentationLimited = false;
    function next(cur, descend) {
      if (descend && cur.firstChild) return cur.firstChild;
      for (let i=0; cur && cur!==root && i<64 && steps++<320; ++i) {
        if (cur.nextSibling) return cur.nextSibling;
        cur=cur.parentNode;
      }
      if (cur && cur!==root) depthLimited = true;
      return null;
    }
    for (let visited=0; node && visited<160 && rows.length<16; ++visited) {
      let descend = true;
      if (node.nodeType === 1) {
        const tag = node.localName;
        descend = !['head','script','style','template','noscript','svg'].includes(tag) &&
          !node.hidden && node.getAttribute('aria-hidden') !== 'true';
        if (tag === 'svg' || tag === 'iframe' || tag === 'canvas' || node.shadowRoot || node.isContentEditable) presentationLimited = true;
        if (descend && visible(node)) {
          const r = role(node);
          const n = r ? label(node) : '';
          if (r && matches(r,n)) {
            const exact = n.length < 40 && !(/[\r\n\u0000]/.test(n));
            const id = exact ? save({kind:'node',node,parent:node.parentElement,role:r,label:n}) : null;
            rows.push({r,n,s:flags(node),ref:id});
          }
        }
      } else if (node.nodeType === 3) {
        const parent = node.parentElement;
        const n = clip(node.nodeValue).trim();
        const pr = parent && role(parent);
        if (n && parent && !interactive(pr) && !['heading','cell','header','option'].includes(pr) &&
            matches('text',n) && visible(parent)) rows.push({r:'text',n});
      }
      node = next(node,descend);
    }
    const continuation = node ? save({kind:'find',node,parent:node.parentNode,input}) : null;
    return {rows,continuation,coverage:depthLimited ? 'depth_limit' : continuation ? 'more' : 'end_of_scope',
      presentationLimited,fieldsTruncated};
  }
  const entry = find(ref);
  if (!entry || entry.kind !== 'node' || !same(entry)) return {error:'stale_ref'};
  const el = entry.node;
  if (!available(el) || el.readOnly || el.closest('[aria-readonly="true"]')) return {error:'not_actionable'};
  let selected;
  let unchanged;
  let desired;
  if (op === 'set_checked' && el instanceof HTMLInputElement && el.type === 'checkbox') {
    const checked = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'checked');
    desired = () => el.type === 'checkbox' && !el.indeterminate && checked.get.call(el) === args;
    unchanged = desired();
    if (!unchanged) {
      checked.set.call(el, args);
      el.indeterminate = false;
    }
  } else if (op === 'select_option' && el instanceof HTMLSelectElement && !el.multiple) {
    const opts = el.options;
    if (opts.length > 256) return {error:'not_actionable'};
    for (let i=0; i<opts.length; ++i) {
      const opt = opts[i];
      if (opt.value !== args) continue;
      // No guessing on duplicates, even if one is disabled.
      if (selected || opt.matches(':disabled')) return {error:'not_actionable'};
      selected = opt;
    }
    if (!selected) return {error:'not_actionable'};
    desired = () => !el.multiple && selected.closest('select') === el && selected.value === args && selected.selected;
    unchanged = desired();
    if (!unchanged) selected.selected = true;
  } else return {error:'not_actionable'};
  if (unchanged) return {outcome:op === 'set_checked' ? 'already_checked_state' : 'already_selected'};
  const intact = () => current() && same(entry) && available(el) && desired();
  el.dispatchEvent(new Event('input', {bubbles:true, composed:true}));
  if (!intact()) return {outcome:'change_dispatched_unconfirmed'};
  el.dispatchEvent(new Event('change', {bubbles:true}));
  if (!intact()) return {outcome:'change_dispatched_unconfirmed'};
  return {outcome:op === 'set_checked' ? 'checked_set' : 'option_selected'};
}
