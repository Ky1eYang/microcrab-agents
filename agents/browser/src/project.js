// Fixed, tool-private function for a Chrome isolated world. All arguments are
// passed as CDP values, never interpolated into this source. Nothing is installed
// into the page's main world. The observe path only reads the live DOM.
function (key, op, ref, input) {
  'use strict';
  const doc = document;
  const root = doc.documentElement;
  const regular = doc.location.protocol === 'http:' || doc.location.protocol === 'https:';
  const blank = doc.URL === 'about:blank';
  const observeOnly = blank || doc.URL.startsWith('chrome://inspect/');
  if (globalThis !== top || !root || (!regular && !(op === 'scan' && observeOnly) && !(op === 'wait_for' && blank))) return {error:'unavailable'};
  let state = globalThis[key];
  const current = () => state && state.root === doc.documentElement && state.url === doc.URL;
  // A fresh overview invalidates older references. Find can start without a
  // snapshot, but doesn't invalidate an existing observation by default.
  if ((op === 'scan' && !ref) || (op === 'find' && !ref && !current())) {
    state = {root, url: doc.URL, refs: new Map(), groups: new WeakMap(), nextGroup: 1};
    globalThis[key] = state;
  }
  const find = id => state.refs.get(id);
  function save(entry) {
    if (state.refs.size >= 256) state.refs.delete(state.refs.keys().next().value);
    const bytes = crypto.getRandomValues(new Uint8Array(16));
    const id = Array.from(bytes, n => n.toString(16).padStart(2, '0')).join('');
    if (state.refs.has(id)) throw new Error('reference collision');
    state.refs.set(id, entry);
    return id;
  }
  const live = node => node && node.isConnected && node.ownerDocument === doc;
  // Bound worst-case JSON escapes, not just JS string length. Truncate
  // valid surrogate pairs at the boundary and replace lone surrogates.
  let fieldsTruncated = false;
  const clip = v => {
    if (typeof v !== 'string') return '';
    if (v.length > 40) fieldsTruncated = true;
    let out = v.slice(0,40);
    if (/[\uD800-\uDBFF]$/.test(out)) out = out.slice(0,-1);
    return out.replace(/[\uD800-\uDFFF]/gu,'\uFFFD');
  };
  function role(el) {
    const explicit = (el.getAttribute('role') || '').slice(0, 40).split(/\s/, 1)[0];
    const tag = el.localName;
    if (tag === 'input') {
      switch (el.type) {
        case 'hidden': return '';
        case 'button': case 'submit': case 'reset': case 'image': return 'button';
        case 'checkbox': case 'radio': return el.type;
        case 'range': return 'slider';
        case 'number': return 'spinbutton';
        default: return explicit || 'textbox';
      }
    }
    const roles = {__proto__:null, button:'button', a:el.hasAttribute('href')?'link':'', textarea:'textbox',
      select:el.multiple?'listbox':'combobox', option:'option', summary:'button',
      dialog:'dialog', form:'form', main:'main', nav:'navigation', section:'region',
      table:'table', tr:'row', td:'cell', th:'header', iframe:'iframe', canvas:'canvas',
      h1:'heading',h2:'heading',h3:'heading',h4:'heading',h5:'heading',h6:'heading'};
    return explicit || roles[tag] ||
      (el.isContentEditable ? 'textbox' : el.hasAttribute('onclick') ? 'possible-button' : '');
  }
  function label(el) {
    const labelled = (el.getAttribute('aria-labelledby') || '').slice(0, 120).trim().split(/\s+/, 3);
    function text(node) {
      let child = node.firstChild;
      let out = '';
      for (let i=0; child && i<6 && out.length<120; ++i, child=child.nextSibling) {
        if (child.nodeType === 3) out += clip(child.nodeValue);
        else if (child.firstChild?.nodeType === 3) out += clip(child.firstChild.nodeValue);
      }
      return clip(out.trim());
    }
    const related = labelled.map(id => doc.getElementById(id)).filter(Boolean).map(text).join(' ');
    const native = el.labels?.[0];
    return clip(related || el.getAttribute('aria-label') || (native && text(native)) || text(el) ||
      el.getAttribute('placeholder') || el.getAttribute('title') || '');
  }
  function flags(el) {
    const f = [];
    for (const [a,n] of [['aria-disabled','disabled'],['aria-readonly','readonly'],['aria-required','required'],
      ['aria-invalid','invalid'],['aria-expanded','expanded'],['aria-selected','selected'],['aria-checked','checked'],['aria-pressed','pressed']]) {
      const value = el.getAttribute(a);
      if (value === 'true') f.push(n);
      else if (value === 'mixed') f.push(n+':mixed');
      else if (value === 'false' && (n === 'expanded' || n === 'checked' || n === 'pressed' || n === 'selected')) f.push(n+':false');
    }
    if (el.matches(':disabled') && !f.includes('disabled')) f.push('disabled');
    if (el.readOnly && !f.includes('readonly')) f.push('readonly');
    if (el.required && !f.includes('required')) f.push('required');
    if (el.matches(':checked') && !f.includes('checked')) f.push('checked');
    if (el.localName === 'option' && el.selected && !f.includes('selected')) f.push('selected');
    if (el === doc.activeElement) f.push('focused');
    return f;
  }
  const interactive = r => ['button','link','textbox','combobox','listbox','option','checkbox','radio','slider',
    'spinbutton','switch','tab','menuitem','menuitemcheckbox','menuitemradio','treeitem','possible-button'].includes(r);
  const textAllowed = el => el.localName === 'textarea' ||
    (el.localName === 'input' && ['text','search','email','url','tel','password'].includes(el.type));
  function available(node) {
    return live(node) && !node.closest('[hidden],[inert],[aria-hidden="true"],[aria-disabled="true"]') &&
      !node.matches(':disabled') && node.checkVisibility({checkOpacity:true, checkVisibilityCSS:true});
  }
  // Legacy projection and effects.
  if (!current()) return {error:'stale_ref'};
  if (op !== 'scan') {
    const entry = find(ref);
    if (!entry || entry.kind !== 'node' || !live(entry.node)) return {error:'stale_ref'};
    const el = entry.node;
    const r = role(el);
    if (el.parentElement !== entry.parent || r !== entry.role || label(el) !== entry.label) return {error:'stale_ref'};
    if (!interactive(r) || !available(el)) return {error:'not_actionable'};
    // Reject before dispatch if the same node was relabelled, moved, or no
    // longer denotes the action shown in the observation.
    const a = el.closest('a[href]');
    if (a && (a.hasAttribute('download') || !/^https?:$/.test(a.protocol) || a.target && a.target !== '_self')) return {error:'not_actionable'};
    if (op === 'click') {
      if (el.localName === 'input' && el.type === 'file') return {error:'not_actionable'};
      el.click();
      return {outcome:'click_dispatched'};
    }
    if (op === 'key') {
      const keys = JSON.parse(input);
      const options = { ...keys, bubbles:true, cancelable:true, composed:true };
      const down = new KeyboardEvent('keydown', options);
      const up = new KeyboardEvent('keyup', options);
      el.dispatchEvent(down);
      // A page handler may move or remove the target. Never send keyup to a
      // different element or a different document.
      if (!live(el) || el.parentElement !== entry.parent || doc.URL !== state.url) return {outcome:'keydown_dispatched_unconfirmed'};
      el.dispatchEvent(up);
      return {outcome:'keys_dispatched'};
    }
    if (op === 'type') {
      if (!textAllowed(el) || el.readOnly || el.closest('[aria-readonly="true"]')) return {error:'not_actionable'};
      // Do not call focus: it can run page code before the intended write.
      const proto = el.localName === 'textarea' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      const decoded = new TextDecoder('utf-8', {fatal:true}).decode(Uint8Array.from(atob(input), c => c.charCodeAt(0)));
      const field = Object.getOwnPropertyDescriptor(proto, 'value');
      field.set.call(el, decoded);
      el.dispatchEvent(new InputEvent('input', {bubbles:true, composed:true, inputType:'insertReplacementText'}));
      return {outcome: live(el) && field.get.call(el) === decoded ? 'text_replaced' : 'input_dispatched_unconfirmed'};
    }
    return {error:'unavailable'};
  }
  const entry = ref ? find(ref) : null;
  if (ref && (!entry || !['node','cursor'].includes(entry.kind) || !live(entry.node) || !live(entry.boundary || entry.node))) return {error:'stale_ref'};
  const boundary = entry?.boundary || entry?.node || root;
  let node = entry?.node || root;
  if (!boundary.contains(node) || (entry?.kind === 'node' && (role(node) !== entry.role || label(node) !== entry.label))) return {error:'stale_ref'};
  const rows = [];
  let visited=0;
  let transitions=0;
  let partial = false;
  let presentationLimited = false;
  function next(cur, descend) {
    if (descend && cur.firstChild) return cur.firstChild;
    for (let i=0; cur && cur!==boundary && i<64 && transitions++<320; ++i) {
      if (cur.nextSibling) return cur.nextSibling;
      cur=cur.parentNode;
    }
    if (cur && cur!==boundary) partial=true;
    return null;
  }
  while (node && visited < 160 && rows.length < 24) {
    ++visited;
    let descend = true;
    if (node.nodeType === 1) {
      const tag=node.localName;
      if (['head','script','style','template','noscript','svg'].includes(tag) || node.hidden ||
          node.getAttribute('aria-hidden') === 'true') {
        descend = false;
        if (tag === 'svg') presentationLimited = true;
      } else {
        const r=role(node);
        if (node.shadowRoot || tag==='iframe' || tag==='canvas' || node.isContentEditable) presentationLimited = true;
        if (r && (r === 'iframe' || r === 'canvas' || node.checkVisibility({checkVisibilityCSS:true}))) {
          const n=label(node);
          const container = node.parentElement?.closest('tr,form,section,dialog,nav,[role="row"],[role="region"],[role="dialog"]');
          const group = container ? label(container) || clip(container.getAttribute('id')) : '';
          let groupId = 0;
          if (container) {
            groupId = state.groups.get(container) || state.nextGroup++;
            state.groups.set(container, groupId);
          }
          const value = textAllowed(node) && node.type !== 'password' ? clip(node.value) : '';
          const errorId = (node.getAttribute('aria-errormessage') || node.getAttribute('aria-describedby') || '').slice(0,120).split(/\s/,1)[0];
          const detail = errorId ? doc.getElementById(errorId) : null;
          if (node.labels?.length && node.localName === 'input' && node.type === 'password') presentationLimited = true;
          const isRegion = ['dialog','form','main','navigation','region','table','row'].includes(r);
          // A clipped name is adequate for reading but not for certifying an
          // exact effect target. Keep its row, without issuing an effect ref.
          const actionRef = interactive(r) && n.length < 40 && !(/[\r\n\u0000]/.test(n));
          const id = actionRef || isRegion ? save({kind:'node',node,parent:node.parentElement,role:r,label:n}) : null;
          rows.push({r,n,g:group,gi:groupId,v:value,s:flags(node),d:detail ? label(detail) : '',ref:id});
        }
      }
    } else if (node.nodeType === 3) {
      const p=node.parentElement;
      const t=clip(node.nodeValue).trim();
      const pr=p && role(p);
      if (t && p && !interactive(pr) && p.checkVisibility({checkVisibilityCSS:true}) &&
          !['heading','cell','header','option'].includes(pr)) rows.push({r:'text',n:t});
    }
    node=next(node,descend);
  }
  const continuation = node ? save({kind:'cursor',node,boundary}) : null;
  return {rows,visited,continuation,coverage: partial ? 'depth_limit' : continuation ? 'more' : 'end_of_scope',
    representation:'light_dom_semantic', presentationLimited, fieldsTruncated};
}
