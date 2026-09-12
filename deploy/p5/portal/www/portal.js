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
/* The last write this session made, kept so the State card can show what the
 * box SAID about it. A refused guard comes back 200 with `detail` carrying the
 * reconciler's own echo -- printing only "ok" would hide the one sentence that
 * answers "why is it still in that state". */
var lastWrite = null;
var NOT_BUILT = 'not built on this box.';

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

/* ONE request site for the whole page (bar UI-4, which counts the call sites of
 * the browser API below and requires exactly one). `asText` is for the two routes
 * whose body is not JSON: the result artifact (U228), whose body is the file
 * itself, and the log tail (U223), whose body is the box's syslog ring streamed
 * rather than escaped (portal-lib.sh p5_hdr_text). A second fetch for either
 * would put a request outside this helper's headers and its session rule -- and
 * outside the bar that counts them, which is the thing UI-4 exists to prevent. */
function req(method, query, body, asText) {
  return fetch(CGI + (query ? '?' + query : ''), {
    method: method,
    headers: body
      ? { 'X-P5-Session': sid, 'Content-Type': 'application/x-www-form-urlencoded' }
      : { 'X-P5-Session': sid },
    body: body || undefined
  }).then(function (r) {
    if (asText) return r.text();
    return r.json().catch(function () { return { ok: false, error: 'bad_json' }; });
  });
}

function enc(o) {
  return Object.keys(o).map(function (k) {
    return encodeURIComponent(k) + '=' + encodeURIComponent(o[k]);
  }).join('&');
}

function post(o) {
  var what = o.k + '=' + (o.op === 'reset' ? '(restore default)' : o.v);
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
    if (r) lastWrite = { what: what, ok: !!r.ok, error: r.error || '', detail: r.detail || '' };
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
      // catalogue column 6 (`impl`): the literals a shipped consumer actually
      // derives something from. Empty = every literal is implemented. A literal
      // outside it is rendered DISABLED and says why, instead of offering a
      // control whose only effect would be the consumer's default. The CGI
      // refuses the same value with 501; the page never becomes the authority.
      var impl = (f.impl || '').split(' ').filter(function (s) { return s !== ''; });
      var unimpl = 0;
      f.domain.split(' ').forEach(function (v) {
        var b = document.createElement('button');
        b.textContent = v;
        if (impl.length > 0 && impl.indexOf(v) < 0) {
          b.disabled = true;
          b.title = 'no derivation on record';
          unimpl = unimpl + 1;
        } else {
          b.onclick = function () { post({ k: f.key, v: v }); };
        }
        row.appendChild(b);
      });
      if (unimpl > 0) {
        var nd = document.createElement('span');
        nd.className = 'pending';
        nd.textContent = ' (no derivation on record)';
        row.appendChild(nd);
      }
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

/* ---- THE TUNNEL AND SHAPING CARDS (U224) ---------------------------------
 *
 * DUMB, like everything else here. The buttons are built from the CATALOGUE
 * rows, so this file names no verb and no argv: a box whose reconciler does not
 * carry a probe simply shows no button for it, and adding one is a catalogue
 * row rather than an edit here.
 *
 * THE ONE PIECE OF ARITHMETIC ON THIS PAGE, and it is here rather than in the
 * CGI on purpose. A byte counter is not a rate; a rate is a delta over a
 * measured interval. The reconciler prints the counters WITH THE BOX'S OWN
 * epoch (`ts=`) and takes no interval itself, because taking one means sleeping
 * inside a uhttpd request. So the operator's two clicks ARE the interval, and
 * the division below uses the two BOX timestamps -- never Date.now(), which
 * would make a browser with a wrong clock, a paused tab or another timezone
 * print a confident and wrong throughput.
 *
 * Nothing here is cumulative and nothing is stored: one previous sample per
 * probe, in this page's memory, gone on reload. A missing or non-numeric field
 * (the probes print `-` for a counter the box does not publish) produces NO
 * line rather than a zero.
 */
var lastProbe = {};                        /* probe name -> key -> its last k=v */
var COUNTERS = ['rx', 'tx', 'txdrop'];     /* the fields a per-second rate means */

/* kvLine: "peer1 rx=10 tx=2 ts=99" / "<if> <dev> rx=.. ts=.." -> {key, kv}.
 * The KEY is the leading bare tokens, so a row identifies itself and this file
 * never has to know whether a row is a peer or a source. */
function kvLine(line) {
  var t = line.split(/\s+/), key = [], kv = {}, i, j;
  for (i = 0; i < t.length; i++) {
    if (!t[i]) continue;
    j = t[i].indexOf('=');
    if (j > 0) kv[t[i].slice(0, j)] = t[i].slice(j + 1);
    else if (!key.length || !Object.keys(kv).length) key.push(t[i]);
  }
  return { key: key.join(' '), kv: kv };
}

function deltaLines(name, text) {
  var out = [], prev = lastProbe[name] || {}, now = {};
  (text || '').split('\n').forEach(function (line) {
    var p = kvLine(line), q, dt, bits;
    if (!p.key || p.kv.ts === undefined) return;
    now[p.key] = p.kv;
    q = prev[p.key];
    if (!q) return;
    dt = Number(p.kv.ts) - Number(q.ts);
    if (!(dt > 0)) return;                 /* same second, or no clock: say nothing */
    bits = [];
    COUNTERS.forEach(function (c) {
      if (p.kv[c] === undefined || q[c] === undefined) return;
      var d = Number(p.kv[c]) - Number(q[c]);
      if (!isFinite(d) || d < 0) return;   /* counter reset: not a rate */
      bits.push(c + ' ' + Math.round(d / dt) + ' B/s');
    });
    if (bits.length) out.push(p.key + ' over ' + dt + 's: ' + bits.join(' · '));
  });
  lastProbe[name] = now;
  return out;
}

function probeLabel(n) {
  var i, p = catRows('probes');
  for (i = 0; i < p.length; i++) { if (p[i].name === n) return p[i].label; }
  return '';
}

/* cardProbes: fill CARDID with one button per catalogue row in NAMES that this
 * box actually carries, printing into OUTID. Returns false when the box carries
 * none, which is what leaves renderPlaceholders' "not built on this box" note
 * in place instead of an empty card. */
function cardProbes(cardId, outId, names) {
  var box = document.getElementById(cardId), have = [], deltas, i;
  for (i = 0; i < names.length; i++) { if (probeNamed(names[i])) have.push(names[i]); }
  if (!have.length) return false;
  box.textContent = '';
  deltas = document.createElement('div');
  deltas.className = 'muted';
  have.forEach(function (n) {
    var b = document.createElement('button');
    b.textContent = n;
    b.title = probeLabel(n);
    b.onclick = function () {
      req('GET', 'q=probe&name=' + encodeURIComponent(n)).then(function (r) {
        var out = document.getElementById(outId), d, e;
        out.hidden = false;
        out.textContent = n + ' (rc=' + (r.rc === undefined ? '?' : r.rc) + ')\n' +
                          (r.output || r.error || '');
        deltas.textContent = '';
        d = deltaLines(n, r.output || '');
        if (!d.length) {
          e = document.createElement('div');
          e.textContent = 'rates: click a counter twice — each read carries the box’s own ' +
                          'timestamp and the interval between two clicks is the measurement.';
          deltas.appendChild(e);
          return;
        }
        d.forEach(function (s) {
          var l = document.createElement('div');
          l.textContent = s;
          deltas.appendChild(l);
        });
      });
    };
    box.appendChild(b);
  });
  box.appendChild(deltas);
  return true;
}

/* Tunnel answers "is the tunnel up, and is anything moving through it"; the two
 * per-source reads are here because the tunnel rides those sources and a dead
 * underlay is the commonest reason the answer above is no. Shaping answers "is
 * the queue attached, and whose is it". */
function renderCards() {
  cardProbes('tunnel', 'tunnelout', ['ep', 'hs', 'xfer', 'ifstats', 'reach']);
  cardProbes('qdisc', 'qdiscout', ['qdisc', 'shape']);
}

/* THE TEST RUNNER (U228). Two cards, and the SPLIT IS THE GUARD: only `ro` rows
 * are rendered here. A `disruptive` row belongs to the red card below, behind
 * the server's own confirm text (U229/U230) -- and until one of those lands the
 * CGI answers 501 for the class, so a row that appeared here by mistake could
 * not be started anyway.
 *
 * NO TIMER (COEX-3). Starting a test refreshes the result list once, and the
 * list has its own button. A page that polls a router every second is a page
 * that costs the box more than the thing it is watching. */
function testsOut(s) {
  var e = document.getElementById('testsout');
  e.hidden = false;
  e.textContent = s;
}

function startTest(name) {
  return req('POST', '', enc({ k: 'run', name: name })).then(function (r) {
    if (r.ok) {
      testsOut('started ' + name + '\nid: ' + r.id + '\n\nIt runs detached: this page can be closed. ' +
               'The artifact appears in Results, RUNNING until its last line is written.');
    } else if (r.error === 'busy') {
      testsOut('refused: another job is running (' + (r.name || '?') + ', id ' + (r.id || '?') +
               '). One at a time.');
    } else if (r.error === 'no_space') {
      testsOut('refused: not enough free space on the results filesystem for another artifact ' +
               'the size of this test’s largest so far. Pull results back first.');
    } else if (r.error === 'disruptive_not_built') {
      testsOut('refused: this row perturbs the datapath and its confirmation path is not built yet.');
    } else {
      testsOut('refused: ' + (r.error || '') + ' ' + (r.detail || ''));
    }
    return refreshResults();
  });
}

function renderTests() {
  var box = document.getElementById('tests');
  var rows = catRows('tests');
  box.textContent = '';
  var any = 0;
  rows.forEach(function (t) {
    if (t.class !== 'ro') { return; }
    any++;
    var b = document.createElement('button');
    b.textContent = t.name;
    b.title = t.label;
    b.onclick = function () { startTest(t.name); };
    box.appendChild(b);
    var lab = document.createElement('div');
    lab.className = 'muted';
    lab.textContent = t.label;
    box.appendChild(lab);
  });
  if (!any) { return; }
  var note2 = document.createElement('div');
  note2.className = 'muted';
  note2.textContent = 'Read-only: these change no fact and start no service. One job at a time.';
  box.appendChild(note2);
}

function showResult(id) {
  return req('GET', 'q=result&id=' + encodeURIComponent(id), null, true).then(function (txt) {
    var out = document.getElementById('resultout');
    out.hidden = false;
    out.textContent = txt;
  });
}

function renderResults(r) {
  var box = document.getElementById('results');
  box.textContent = '';
  var go = document.createElement('button');
  go.textContent = 'refresh results';
  go.onclick = refreshResults;
  box.appendChild(go);
  var list = (r && r.results) || [];
  if (!list.length) {
    var none = document.createElement('div');
    none.className = 'muted';
    none.textContent = 'No result artifacts on the box yet.';
    box.appendChild(none);
    return;
  }
  list.forEach(function (a) {
    var row = document.createElement('div');
    var b = document.createElement('button');
    b.textContent = a.id;
    b.onclick = function () { showResult(a.id); };
    row.appendChild(b);
    var m = document.createElement('span');
    m.className = 'muted';
    m.textContent = a.status + ' · ' + a.bytes + ' bytes' +
      (a.status === 'INCOMPLETE' ? ' · no end marker: the job did not finish' : '');
    row.appendChild(m);
    box.appendChild(row);
  });
  var why = document.createElement('div');
  why.className = 'muted';
  why.textContent = 'Artifacts live outside the web root and are served only through this session. ' +
    'Nothing deletes them; pull them back before a firmware upgrade.';
  box.appendChild(why);
}

function refreshResults() {
  return req('GET', 'q=results').then(function (r) {
    if (!r.ok) { err('results: ' + (r.error || '')); return; }
    renderResults(r);
  });
}

/* ============================ DATAPATH (U226) ==============================
 * The reader is `p5-reconciler _stats`: one `age_s=` line, then the daemon's
 * stats file verbatim (grammar fixed in the portal plan §9; writer is
 * daemon/stats.go). Everything below is PARSING, never arithmetic on this
 * browser's clock -- the age is computed on the box, because a phone whose clock
 * is thirty seconds off must not be able to make a healthy datapath read stale.
 *
 * TOLERATES UNKNOWN TOKENS BY CONSTRUCTION. Each segment is split into k=v pairs
 * and only the keys named here are looked up, so a key the daemon adds later
 * still reaches the operator through the raw <pre> without an edit here.
 *
 * NOTHING IS INVENTED. Every row that has no token to render says which token is
 * missing instead of printing a zero: an empty number on this card would be read
 * as "measured, and it is zero", which is the one thing this page must not say.
 */
var lastStats = null;   /* {ts, kb:{}} of the PREVIOUS read -- throughput is a delta */

function stKV(seg) {                 /* "a=1 b=2 BARE" -> {a:'1', b:'2'} */
  var o = {}, t = seg.split(/\s+/), i, e;
  for (i = 0; i < t.length; i++) { e = t[i].indexOf('='); if (e > 0) o[t[i].slice(0, e)] = t[i].slice(e + 1); }
  return o;
}

function stParse(out) {
  var s = { absent: '', age: null, head: {}, ival: null, links: [], loss: {}, lit: null, latency: '' };
  var lines = String(out == null ? '' : out).split('\n'), i, j, ln, segs, seg, name, kv, p;
  for (i = 0; i < lines.length; i++) {
    ln = lines[i];
    if (i === 0 && ln.indexOf('absent:') === 0) { s.absent = ln; return s; }
    if (i === 0 && ln.indexOf('age_s=') === 0) {
      if (/^-?[0-9]+$/.test(ln.slice(6))) s.age = parseInt(ln.slice(6), 10);
      continue;                                  /* age_s=unknown leaves it null */
    }
    if (ln.indexOf('ts=') === 0) {
      segs = ln.split(' | ');                    /* header | per link | LIT */
      s.head = stKV(segs[0]);
      for (j = 1; j < segs.length; j++) {
        seg = segs[j].replace(/\s+$/, '');
        name = seg.split(/\s+/)[0];
        if (name === 'LIT') { s.lit = stKV(seg); continue; }
        kv = stKV(seg); kv.name = name; kv.inert = / INERT$/.test(seg);
        s.links.push(kv);
      }
      continue;
    }
    if (ln.indexOf('link ') === 0) {             /* link <name> loss_pct=<v> */
      p = ln.split(/\s+/);
      if (p[1]) s.loss[p[1]] = stKV(ln).loss_pct;
      continue;
    }
    if (ln.indexOf('latency ') === 0) { s.latency = ln; }
  }
  if (/^[0-9]+$/.test(s.head.ival_ms || '')) s.ival = parseInt(s.head.ival_ms, 10) / 1000;
  return s;
}

/* FRESH / STALE / ABSENT. The threshold is TWO TICKS and the tick length is the
 * file's own ival_ms -- this page carries no cadence constant, so it cannot
 * drift from the daemon the day that tick changes. When the file states no
 * cadence the question is left OPEN rather than answered against a guess. */
function stFresh(s) {
  if (s.absent) return { cls: 'pending', text: s.absent };
  if (s.age === null) return { cls: 'pending', text: 'age unknown — no ts= on the first line (truncated, or not this daemon’s file)' };
  if (s.age < 0) return { cls: 'pending', text: 'clock skew — the file is stamped ' + (-s.age) + 's in the future' };
  if (s.ival === null) return { cls: 'pending', text: s.age + 's old; the file states no ival_ms=, so fresh vs stale is not decided here' };
  if (s.age <= 2 * s.ival) return { cls: '', text: 'fresh — ' + s.age + 's old (tick ' + s.ival + 's)' };
  return { cls: 'pending', text: 'stale — ' + s.age + 's old, more than two ' + s.ival + 's ticks; the datapath may have stopped' };
}

/* Throughput from the per-link kb= counters between two reads, divided by the
 * two BOX timestamps -- never by wall time here, and never by a sleep in the
 * CGI. A counter that went backwards is a restarted daemon, said so rather than
 * rendered as a negative rate. */
function stRate(s) {
  var ts = /^[0-9]+$/.test(s.head.ts || '') ? parseInt(s.head.ts, 10) : null;
  var cur = { ts: ts, kb: {} }, i, n, prev, d, dt, rows = [], tot = 0, any = false, out = null;
  for (i = 0; i < s.links.length; i++) cur.kb[s.links[i].name] = parseInt(s.links[i].kb, 10);
  if (lastStats && ts !== null && lastStats.ts !== null && ts > lastStats.ts) {
    dt = ts - lastStats.ts;
    for (n in cur.kb) {
      if (!Object.prototype.hasOwnProperty.call(cur.kb, n)) continue;
      prev = lastStats.kb[n];
      if (prev === undefined || isNaN(cur.kb[n]) || isNaN(prev)) continue;
      d = cur.kb[n] - prev;
      if (d < 0) { rows.push(n + ' counter reset'); continue; }
      any = true; tot += d;
      rows.push(n + ' ' + (d / dt).toFixed(1) + ' KiB/s');
    }
    out = { dt: dt, rows: rows, total: any ? (tot / dt).toFixed(1) : null };
  }
  lastStats = cur;
  return out;
}

function stRow(parent, label, value, cls) {
  var d = document.createElement('div'), b = document.createElement('b'), v = document.createElement('span');
  b.textContent = label + ': ';
  if (cls) v.className = cls;
  v.textContent = (value === '' || value == null) ? '—' : value;
  d.appendChild(b); d.appendChild(v); parent.appendChild(d);
}

function stRender(box, r) {
  box.textContent = '';
  if (!r || r.ok !== true) { stRow(box, 'read', (r && r.error) || 'the read failed', 'pending'); return; }
  var s = stParse(r.output), f = stFresh(s), tp, ls = [], caps = [], i, n, L;
  stRow(box, 'file', f.text, f.cls);
  if (s.absent) { lastStats = null; return; }   /* nothing measured -> nothing shown */
  stRow(box, 'scheduler', s.head.sched || 'no sched= token', s.head.sched ? '' : 'pending');
  tp = stRate(s);
  stRow(box, 'throughput',
        tp ? (tp.rows.join(' · ') + (tp.total ? ' — total ' + tp.total + ' KiB/s' : '') + ' (over ' + tp.dt + 's)')
           : 'needs a second read — it is a delta between two of the box’s own timestamps',
        tp ? '' : 'pending');
  for (n in s.loss) { if (Object.prototype.hasOwnProperty.call(s.loss, n)) ls.push(n + ' ' + s.loss[n] + '%'); }
  stRow(box, 'loss', ls.length ? ls.join(' · ') : 'no per-link loss lines in the file', ls.length ? '' : 'pending');
  stRow(box, 'hold', s.head.hold || 'no hold= token', s.head.hold ? '' : 'pending');
  for (i = 0; i < s.links.length; i++) {
    L = s.links[i];
    if (L.cap === undefined) continue;
    caps.push(L.name + ' ' + (L.cap === '1' ? 'latched' : 'not latched') +
              (L.inert ? ' INERT (echoes arriving, nothing aligned)' : '') + (L.far ? ' far=' + L.far : ''));
  }
  stRow(box, 'cap', caps.length ? caps.join(' · ') : 'not armed — the datapath prints no cap fragment', caps.length ? '' : 'pending');
  stRow(box, 'duplication', s.lit
        ? ('on — nominated ' + (s.lit.nom || '?') + ', admitted ' + (s.lit.adm || '?') + ', refused ' + (s.lit.refused || '?'))
        : 'off — the datapath prints no LIT fragment', s.lit ? '' : 'pending');
  /* VERBATIM, deliberately: the file says `absent` because the daemon measures
   * no delivery-latency percentiles, and re-wording it here is how an `absent`
   * turns into a 0 two edits later. */
  stRow(box, 'latency', s.latency || 'no latency line in the file', 'pending');
}

function renderStats() {
  var box = document.getElementById('stats'), b = document.createElement('button'),
      hint = document.createElement('div'), out = document.createElement('div');
  box.textContent = '';
  b.textContent = 'read datapath stats';
  b.title = 'one p5-reconciler _stats — a click, never a timer (design §3 coexistence)';
  hint.className = 'pending';
  hint.textContent = 'Click once to sample; click again for throughput, which is a delta between the two samples.';
  b.onclick = function () {
    req('GET', 'q=probe&name=stats').then(function (r) {
      var raw = document.getElementById('statsout');
      raw.hidden = false;
      raw.textContent = 'stats (rc=' + (r.rc === undefined ? '?' : r.rc) + ')\n' + (r.output || r.error || '');
      stRender(out, r);
    });
  };
  box.appendChild(b); box.appendChild(hint); box.appendChild(out);

/* THE LOG TAIL (U223). The picker is built from catalogue/logs, so this file
 * still enumerates nothing: add a row on the box and the option appears. The
 * body arrives as TEXT and is written with .textContent into a <pre> -- the
 * second layer behind the route's own text/plain + nosniff + CSP, and the reason
 * a ring line carrying markup is a line and not a tag.
 *
 * TWO THINGS THIS PRINTS THAT A NAIVE TAIL DOES NOT, both because the ring is a
 * BUFFER and not a file:
 *  - the count and the first/last line it actually received, so an empty middle
 *    is visibly "the ring does not go back that far" rather than "it never
 *    happened". That distinction is the whole debugging value of this card.
 *  - for the empty answer, the reason in words. Empty is a 200 from the CGI --
 *    "no line carrying this tag is in the ring right now" is an answer, and the
 *    one you get when the 1 Hz datapath counter has already pushed the refusal
 *    you are hunting out of the buffer. */
function logSummary(name, lines) {
  if (!lines.length) {
    return 'No line carrying the ' + name + ' tag is in the ring right now. ' +
           'The ring is the box’s own fixed-size buffer: while the datapath is ' +
           'engaged its 1 Hz counter line can push an older one out of it, so this ' +
           'is not evidence that nothing was logged.';
  }
  return lines.length + ' line(s) in the ring. First: ' + lines[0] +
         ' — last: ' + lines[lines.length - 1];
}

function renderLogs() {
  var rows = catRows('logs');
  if (!rows.length) return;              /* renderPlaceholders owns the card */
  var sel = document.getElementById('logsrc');
  var box = document.getElementById('logs');
  var out = document.getElementById('logout');
  sel.textContent = '';
  rows.forEach(function (r) {
    var o = document.createElement('option');
    o.value = r.name;
    o.textContent = r.name;
    o.title = r.label;
    sel.appendChild(o);
  });
  sel.hidden = false;
  box.textContent = '';
  var b = document.createElement('button');
  b.textContent = 'read';
  var lab = document.createElement('div');
  lab.className = 'muted';
  var sum = document.createElement('div');
  sum.className = 'muted';
  function describe() {
    var i = sel.selectedIndex;
    lab.textContent = (i < 0) ? '' : rows[i].label;
  }
  sel.onchange = describe;
  describe();
  b.onclick = function () {
    var name = sel.value;
    req('GET', 'q=log&src=' + encodeURIComponent(name), null, true).then(function (t) {
      var body = t || '';
      /* A refusal is still JSON (the CGI decides every 4xx/5xx before it writes
       * a text header), so say what it said instead of pasting a brace. */
      if (body.charAt(0) === '{') {
        var e = '';
        try { e = (JSON.parse(body).error || ''); } catch (x) { e = 'bad_json'; }
        sum.textContent = 'refused: ' + e;
        out.hidden = true;
        return;
      }
      var lines = body.split('\n').filter(function (l) { return l !== ''; });
      sum.textContent = logSummary(name, lines);
      out.hidden = !lines.length;
      out.textContent = lines.join('\n');
    });
  };
  box.appendChild(b);
  box.appendChild(lab);
  box.appendChild(sum);
}

/* CARDS WHOSE UNIT HAS NOT LANDED (U222). The skeleton fixes the card order and
 * the ids BEFORE the units that fill them exist, so each such card has to say
 * so in its own words: an empty card reads as a measured zero, and a measured
 * zero is the one thing this page must never print about something it did not
 * read. The test is the CATALOGUE, never a version string -- when U223/U224/
 * U226/U228 add their rows the card fills itself with no edit here. */
function catRows(k) { return (cat && cat[k] && cat[k].length) ? cat[k] : []; }
function probeNamed(n) {
  var i, p = catRows('probes');
  for (i = 0; i < p.length; i++) { if (p[i].name === n) return true; }
  return false;
}
function note(id, s) {
  var e = document.getElementById(id);
  if (e.childNodes.length) return;            /* a landed unit already owns it */
  var d = document.createElement('div');
  d.className = 'pending';
  d.textContent = s;
  e.appendChild(d);
}
function renderPlaceholders() {
  if (!probeNamed('hs') && !probeNamed('xfer') && !probeNamed('ep')) {
    note('tunnel', 'Handshake age, transfer deltas and the endpoint class are ' + NOT_BUILT);
  }
  if (!probeNamed('qdisc') && !probeNamed('shape')) {
    note('qdisc', 'The qdisc and shaper-ownership read is ' + NOT_BUILT);
  }
  if (!probeNamed('stats')) {
    note('stats', 'The datapath stats reader is ' + NOT_BUILT +
                  ' Throughput, loss and cap state are not shown rather than invented.');
  }
  if (!catRows('logs').length) { note('logs', 'The log tail is ' + NOT_BUILT); }
  var t = catRows('tests'), i, ndis = 0;
  for (i = 0; i < t.length; i++) { if (t[i].class === 'disruptive') ndis++; }
  if (!t.length) {
    note('tests', 'The on-box test runner is ' + NOT_BUILT);
    note('results', 'No result artifacts: the runner that writes them is ' + NOT_BUILT);
  }
  if (!ndis) {
    note('disruptive', 'No action here perturbs the datapath yet: the gated rows are ' + NOT_BUILT);
  }
}

/* What this CGI would actually call (U220's q=state fields). It is printed
 * BEFORE any click so a deploy step can see whether the portal is wired to P5's
 * own paths or to the old stack's, without pressing anything. */
function renderResolved(s) {
  var e = document.getElementById('resolved');
  if (s.root == null && s.bondctl == null && s.xctl == null && s.uid == null) {
    e.textContent = 'This CGI does not report its resolved paths or uid — ' + NOT_BUILT;
    return;
  }
  var x = function (p, f) {
    return (p == null || p === '' ? '?' : p) + (String(f) === '1' ? '' : ' (NOT EXECUTABLE)');
  };
  e.textContent =
    'uid ' + (s.uid == null ? '?' : s.uid) +
    ' · root ' + (s.root == null ? '?' : s.root) +
    ' · lifecycle/mode ' + x(s.bondctl, s.bondctl_x) +
    ' · reconcile ' + x(s.xctl, s.xctl_x) +
    ' · PATH ' + (s.path == null ? '?' : s.path);
}

function renderLastWrite() {
  var e = document.getElementById('writedetail');
  if (!lastWrite) { e.textContent = 'nothing written from this page in this session.'; return; }
  e.textContent = lastWrite.what + ' — ' +
    (lastWrite.ok ? 'accepted' : ('refused: ' + lastWrite.error)) +
    (lastWrite.detail ? ' · ' + lastWrite.detail : '');
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
    /* Rendered in the order the cards appear (U222): State's pair, its two
     * controls, the last write, the resolved paths -- then Divergence. */
    renderPair(s);
    renderModes(s);
    renderFields(s);
    renderLastWrite();
    renderResolved(s);
    txt('kmwan', s.kmwan);
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

/* FAIL CLOSED IN THE PAGE TOO. The CGI is the gate; this only stops the page
 * from showing a wall of empty cards, which would read as "the box has nothing
 * running" when what happened is that the session was refused. */
function showCards(on) { document.getElementById('cards').hidden = !on; }

function start() {
  if (!sid) { err('no session id'); showCards(false); return; }
  req('GET', 'q=catalogue').then(function (c) {
    if (!c.ok) {
      err('catalogue: ' + (c.error || '') + ' (403 means the session was not accepted)');
      showCards(false); return;
    }
    showCards(true);
    cat = c;
    renderProbes();
    /* BEFORE renderPlaceholders, deliberately: note() refuses to overwrite a
     * card a landed unit already owns, so a card this unit filled keeps its
     * buttons and a card whose rows this box lacks still gets its note. */
    renderCards();
    renderTests();
    refreshResults();
    /* Driven by the CATALOGUE, never by a version string (U222's rule): a box
     * whose reconciler predates U226 has no `stats` row, so the card keeps the
     * skeleton's "not built on this box" note instead of a dead button. This
     * runs BEFORE renderPlaceholders so the note sees the card already owned. */
    if (probeNamed('stats')) renderStats();

    renderLogs();               /* before the placeholders: a landed card owns itself */
    renderPlaceholders();
    document.getElementById('srcrefresh').onclick = refreshSources;
    refresh();
    refreshSources();
  });
}

boot();
