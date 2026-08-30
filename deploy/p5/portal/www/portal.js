/* deploy/p5/portal/www/portal.js — the M9 portal page.
 *
 * DUMB BY DESIGN. Every decision that matters is made in the CGI:
 *  - the mode list comes from catalogue/modes over ?q=catalogue. NOTHING here
 *    enumerates a mode name, a source count, a source name or a rate. Change
 *    the catalogue and this page changes with it (design §3, N-generic rule).
 *  - `intent` and `position` arrive as TWO fields from the CGI. This file only
 *    renders what it is given, so the ADR-003 rule-5 pair cannot be conflated
 *    by a client-side shortcut.
 *  - every value is written with textContent, never innerHTML. Combined with
 *    the CGI's JSON escaper that is the second layer against injection surface
 *    INJ-2: even a fact file edited by hand to contain markup renders as text.
 */
'use strict';
var CGI = 'cgi-bin/p5-portal';
var sid = sessionStorage.getItem('p5sid') || '';
var cat = null;

function txt(id, s) { var e = document.getElementById(id); e.textContent = (s === '' || s == null) ? '—' : s; }
function err(s) { document.getElementById('err').textContent = s || ''; }

/* The session id. WHICH cookie GL's login sets is NOT established (see the
 * authentication note in lib/portal-lib.sh): so we look for any cookie whose
 * value has the shape of a session id, and fall back to asking. It is sent in a
 * custom header, never relied on as an ambient cookie — that is what stops a
 * third-party page from driving this CGI with the operator's session. */
function sniffCookie() {
  var parts = (document.cookie || '').split(';');
  for (var i = 0; i < parts.length; i++) {
    var v = parts[i].split('=').slice(1).join('=').trim();
    if (/^[0-9a-fA-F]{32}$/.test(v)) return v;
  }
  return '';
}

function req(method, query, body) {
  return fetch(CGI + (query ? '?' + query : ''), {
    method: method,
    headers: body
      ? { 'X-P5-Session': sid, 'Content-Type': 'application/x-www-form-urlencoded' }
      : { 'X-P5-Session': sid },
    body: body || undefined
  }).then(function (r) { return r.json().catch(function () { return { ok: false, error: 'bad_json' }; }); });
}

function enc(o) {
  return Object.keys(o).map(function (k) {
    return encodeURIComponent(k) + '=' + encodeURIComponent(o[k]);
  }).join('&');
}

function post(o) {
  return req('POST', '', enc(o)).then(function (r) {
    if (r.error === 'confirm_required') {
      var msg = 'Auto off will pin "' + r.pin + '" (where the system is now).\n\n' +
                'OK pins "' + r.pin + '" and then selects "' + r.selecting + '".\n' +
                'Cancel leaves the supervised policy on.';
      if (!confirm(msg)) return null;          /* ADR-003 rule 4: never silent */
      o.confirm = r.pin;
      return req('POST', '', enc(o));
    }
    return r;
  }).then(function (r) {
    if (r && !r.ok) err('error: ' + (r.error || '') + ' ' + (r.detail || ''));
    else err('');
    return refresh();
  });
}

function renderModes(state) {
  var box = document.getElementById('modebtns');
  box.textContent = '';
  cat.modes.forEach(function (m) {
    var b = document.createElement('button');
    b.textContent = m.value;
    b.title = m.note;
    if (m.status !== 'implemented') { b.disabled = true; b.textContent = m.value + ' (not built)'; }
    b.onclick = function () { post({ k: 'mode', v: m.value }); };
    box.appendChild(b);
  });
  var note = document.createElement('div');
  note.className = 'muted';
  note.textContent = 'Selecting "eco" enables the supervised policy. Any other mode pins it manually.';
  box.appendChild(note);
}

function renderFields(state) {
  var box = document.getElementById('fields');
  box.textContent = '';
  cat.fields.forEach(function (f) {
    var row = document.createElement('div');
    var lab = document.createElement('div');
    lab.textContent = f.label;
    row.appendChild(lab);
    var cur = document.createElement('span');
    cur.className = 'muted';
    cur.textContent = 'current: ' + (state.facts[f.key] || '—') + '  ';
    row.appendChild(cur);
    if (f.kind === 'enum') {
      f.domain.split(' ').forEach(function (v) {
        var b = document.createElement('button');
        b.textContent = v;
        b.onclick = function () { post({ k: f.key, v: v }); };
        row.appendChild(b);
      });
    } else {
      var inp = document.createElement('input');
      inp.size = 10;
      var go = document.createElement('button');
      go.textContent = 'set';
      if (!state.floor_envelope) {
        inp.disabled = true; go.disabled = true;
        var why = document.createElement('span');
        why.className = 'pending';
        why.textContent = ' disabled: no declared envelope, and there is no non-arbitrary ceiling to invent. ' +
                          'The derived one is OBJ-F (not built).';
        row.appendChild(inp); row.appendChild(go); row.appendChild(why);
        box.appendChild(row); return;
      }
      go.onclick = function () { post({ k: f.key, v: inp.value }); };
      row.appendChild(inp); row.appendChild(go);
    }
    var rst = document.createElement('button');
    rst.textContent = 'restore default';
    rst.onclick = function () { post({ k: f.key, op: 'reset' }); };
    row.appendChild(rst);
    if (f.consumer !== 'built') {
      var p = document.createElement('span');
      p.className = 'pending';
      p.textContent = ' — the fact is written per its spec, but no shipped artifact reads it yet.';
      row.appendChild(p);
    }
    box.appendChild(row);
  });
}

function renderProbes() {
  var box = document.getElementById('probes');
  box.textContent = '';
  cat.probes.forEach(function (p) {
    var b = document.createElement('button');
    b.textContent = p.name;
    b.title = p.label;
    b.onclick = function () {
      req('GET', 'q=probe&name=' + encodeURIComponent(p.name)).then(function (r) {
        var out = document.getElementById('probeout');
        out.hidden = false;
        out.textContent = p.name + ' (rc=' + (r.rc === undefined ? '?' : r.rc) + ')\n' + (r.output || r.error || '');
      });
    };
    box.appendChild(b);
  });
}

/* THE PAIR (design §2). Two readouts, never one. `position` is shown only when
 * the CGI sends one, i.e. only under auto — showing the raw mode as "the
 * selection" is exactly the bug ADR-003 rule 5 was written for. */
function renderPair(s) {
  txt('intent', s.intent);
  txt('node', s.node);
  txt('auto', s.auto);
  var row = document.getElementById('posrow');
  if (s.position) {
    row.hidden = false;
    txt('position', s.intent + ' — currently on ' + s.position);
  } else {
    row.hidden = true;
  }
}

function renderSources(s) {
  var tb = document.getElementById('sources');
  tb.textContent = '';
  /* N-GENERIC: however many rows arrive, in whatever order. No index is
   * privileged, nothing is labelled first/second, nothing is truncated. */
  s.sources.forEach(function (src) {
    var tr = document.createElement('tr');
    [src.iface, src.device, src.state, src.metric, src.metered].forEach(function (c) {
      var td = document.createElement('td');
      td.textContent = (c === '' || c == null) ? '—' : c;
      tr.appendChild(td);
    });
    tb.appendChild(tr);
  });
}

function refresh() {
  return req('GET', 'q=state').then(function (s) {
    if (!s.ok) { err('state: ' + (s.error || '')); return; }
    renderPair(s);
    txt('kmwan', s.kmwan);
    renderFields(s);
    renderModes(s);
  });
}

/* Sources are fetched on their own, not with every state poll: the box has to
 * be asked about every declared interface over ubus, which is much the most
 * expensive read the portal makes. */
function refreshSources() {
  return req('GET', 'q=sources').then(function (s) {
    if (!s.ok) { err('sources: ' + (s.error || '')); return; }
    renderSources(s);
  });
}

function boot() {
  document.getElementById('sid').value = sid;
  document.getElementById('authnote').textContent =
    'Reuses the box’s own session rather than a second credential store. ' +
    'Which cookie the vendor login sets is not established here, so paste the id if it is not detected.';
  document.getElementById('authgo').onclick = function () {
    sid = document.getElementById('sid').value.trim();
    sessionStorage.setItem('p5sid', sid);
    start();
  };
  if (!sid) { sid = sniffCookie(); document.getElementById('sid').value = sid; }
  start();
}

function start() {
  if (!sid) { err('no session id'); return; }
  req('GET', 'q=catalogue').then(function (c) {
    if (!c.ok) { err('catalogue: ' + (c.error || '') + ' (403 means the session was not accepted)'); return; }
    cat = c;
    renderProbes();
    document.getElementById('srcrefresh').onclick = refreshSources;
    refresh();
    refreshSources();
  });
}

boot();
