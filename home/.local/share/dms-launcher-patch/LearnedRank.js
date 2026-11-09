.pragma library
// Learned ranking for the DMS launcher (dms-launcher-patch #19).
//
// Copied into Modals/DLauncherV2/ by dms-launcher-patch; edit THIS file:
//   ~/.local/share/dms-launcher-patch/LearnedRank.js
// State is persisted by the Controller (a FileView) at
//   ~/.local/state/dms-launcher-learn.json
//
// Two things are learned from every pick (Enter / click on a result):
//   items[key]     how much you use a result, decaying with time
//   queries[q][key] which result you picked after typing q, decaying too
// key = "<type>:<id>" (the same key DMS's own usage history uses).
//
// Scores are decayed counts: each pick adds 1, and the total halves every
// HALF_LIFE_DAYS, so a file used daily outranks one used 30 times last year.

var HALF_LIFE_MS = 14 * 24 * 3600 * 1000;
var MAX_QUERIES = 600;
var MAX_ITEMS = 1500;
var MAX_PER_QUERY = 8;

var S = { v: 1, items: {}, queries: {} };

// ── folder priority (~/.config/dms/launcher-folder-priority.json) ──────
// { "folders": { "~/Work": 15, "~/.cache": -30, "~/.claude/projects/*/memory": 5 } }
// Longest match wins; '*' = exactly one folder name. Clamped to -50..50.
var PRIO = [];

function loadPriority(text, home) {
    var out = [];
    try {
        var f = (JSON.parse(text || "{}").folders) || {};
        for (var k in f) {
            var v = Number(f[k]);
            if (!isFinite(v))
                continue;
            var path = String(k).replace(/^~(?=\/|$)/, home || "").replace(/\/+$/, "");
            var segs = path.split("/");
            out.push({ segs: segs, n: segs.length, v: Math.max(-50, Math.min(50, v)) });
        }
    } catch (e) {
        out = [];
    }
    out.sort(function (a, b) {
        return b.n - a.n; // longest first: the first hit wins
    });
    PRIO = out;
}

function folderPriority(path) {
    if (!PRIO.length || !path)
        return 0;
    var p = String(path).split("/");
    for (var i = 0; i < PRIO.length; i++) {
        var r = PRIO[i];
        if (p.length < r.n)
            continue;
        var ok = true;
        for (var j = 0; j < r.n; j++)
            if (r.segs[j] !== "*" && r.segs[j] !== p[j]) {
                ok = false;
                break;
            }
        if (ok)
            return r.v;
    }
    return 0;
}

function load(text) {
    try {
        var d = JSON.parse(text || "{}");
        S = {
            v: 1,
            items: d.items || {},
            queries: d.queries || {}
        };
    } catch (e) {
        S = { v: 1, items: {}, queries: {} };
    }
}

function dump() {
    return JSON.stringify(S);
}

function now() {
    return Date.now();
}

function decayed(w, last, t) {
    if (!w || !last)
        return 0;
    return w * Math.pow(0.5, Math.max(0, t - last) / HALF_LIFE_MS);
}

// "  /F  Env " -> "env". Mode prefixes (/f, /d, ...) are not what you mean.
function normQuery(q) {
    var s = String(q || "").toLowerCase().replace(/\s+/g, " ").trim();
    s = s.replace(/^\/[a-z]\s+/, "");
    return s;
}

function keyFor(item) {
    if (!item || !item.id || !item.type)
        return "";
    return item.type + ":" + item.id;
}

function record(query, item) {
    var key = keyFor(item);
    if (!key)
        return false;
    var t = now();
    var it = S.items[key] || { w: 0, last: 0 };
    it.w = decayed(it.w, it.last, t) + 1;
    it.last = t;
    it.type = item.type;
    it.name = item.name || "";
    if (item.type === "file") {
        it.path = item.data?.path || item.id;
        it.dir = !!item.data?.is_dir;
    }
    S.items[key] = it;

    var q = normQuery(query);
    if (q.length > 0) {
        var bucket = S.queries[q] || {};
        var e = bucket[key] || { w: 0, last: 0 };
        e.w = decayed(e.w, e.last, t) + 1;
        e.last = t;
        bucket[key] = e;
        // Keep each query's list short: drop its weakest entries.
        var ks = Object.keys(bucket);
        if (ks.length > MAX_PER_QUERY) {
            ks.sort(function (a, b) {
                return decayed(bucket[b].w, bucket[b].last, t) - decayed(bucket[a].w, bucket[a].last, t);
            });
            for (var i = MAX_PER_QUERY; i < ks.length; i++)
                delete bucket[ks[i]];
        }
        bucket._last = t;
        S.queries[q] = bucket;
    }
    prune(t);
    _cache = {};
    return true;
}

function prune(t) {
    var qs = Object.keys(S.queries);
    if (qs.length > MAX_QUERIES) {
        qs.sort(function (a, b) {
            return (S.queries[b]._last || 0) - (S.queries[a]._last || 0);
        });
        for (var i = MAX_QUERIES; i < qs.length; i++)
            delete S.queries[qs[i]];
    }
    var ks = Object.keys(S.items);
    if (ks.length > MAX_ITEMS) {
        ks.sort(function (a, b) {
            return decayed(S.items[b].w, S.items[b].last, t) - decayed(S.items[a].w, S.items[a].last, t);
        });
        for (var j = MAX_ITEMS; j < ks.length; j++)
            delete S.items[ks[j]];
    }
}

// Decayed usage of one result, regardless of query.
function usage(item) {
    var it = S.items[keyFor(item)];
    return it ? decayed(it.w, it.last, now()) : 0;
}

// How strongly the current query points at each result, from past picks:
//   same query                        x1.0
//   you typed less than last time     x0.7  ("en" when you picked after "env")
//   you typed more than last time     x0.5  ("envx" after picking at "env")
// Returns { key: affinity }. Cached per query until the next pick.
var _cache = {};
function affinities(query) {
    var q = normQuery(query);
    if (!q)
        return {};
    if (_cache[q])
        return _cache[q];
    var t = now();
    var out = {};
    var stored = Object.keys(S.queries);
    for (var i = 0; i < stored.length; i++) {
        var sq = stored[i];
        var f = sq === q ? 1.0 : (sq.length > q.length && sq.indexOf(q) === 0) ? 0.7 : (q.length > sq.length && q.indexOf(sq) === 0 && sq.length >= 2) ? 0.5 : 0;
        if (!f)
            continue;
        var bucket = S.queries[sq];
        for (var k in bucket) {
            if (k === "_last")
                continue;
            var a = decayed(bucket[k].w, bucket[k].last, t) * f;
            if (a > 0)
                out[k] = (out[k] || 0) + a;
        }
    }
    _cache[q] = out;
    return out;
}

function affinity(query, item) {
    return affinities(query)[keyFor(item)] || 0;
}

// Score bonus for the stock Scorer (apps, plugins, settings, ...): query
// affinity dominates (up to 6000: enough for a prefix match you always pick
// to beat an exact match you never pick), plus a recency-weighted usage bonus.
function scorerBonus(query, item) {
    return Math.min(6000, affinity(query, item) * 2500) + Math.min(1500, usage(item) * 150);
}

// Re-rank dsearch hits (already in dsearch's relevance order): position-based
// base score plus learned bonuses. Stable for results you never picked.
function rerankFiles(query, items) {
    var n = items.length;
    var scored = items.map(function (it, i) {
        return {
            it: it,
            s: (n - i) + Math.min(30, affinity(query, it) * 12) + Math.min(10, usage(it) * 2) + folderPriority(it.data?.path || it.id),
            i: i
        };
    });
    scored.sort(function (a, b) {
        return b.s !== a.s ? b.s - a.s : a.i - b.i;
    });
    return scored.map(function (x) {
        return x.it;
    });
}

// Files/folders you picked before that match the query, for re-adding when
// dsearch's top-N missed them. Every query word must occur in the name
// (or path, for multi-word queries). Returns [{path, dir}] best first.
function knownFiles(query, wantType, limit) {
    var q = normQuery(query);
    if (q.length < 2)
        return [];
    var words = q.split(" ");
    var t = now();
    var aff = affinities(query);
    var res = [];
    for (var k in S.items) {
        var it = S.items[k];
        if (it.type !== "file" || !it.path)
            continue;
        if (wantType === "file" && it.dir || wantType === "dir" && !it.dir)
            continue;
        var base = it.path.substring(it.path.lastIndexOf("/") + 1).toLowerCase();
        var hay = words.length > 1 ? it.path.toLowerCase() : base;
        var ok = true;
        for (var w = 0; w < words.length; w++)
            if (hay.indexOf(words[w]) < 0) {
                ok = false;
                break;
            }
        if (!ok)
            continue;
        res.push({ path: it.path, dir: !!it.dir, s: (aff[k] || 0) * 3 + decayed(it.w, it.last, t) });
    }
    res.sort(function (a, b) {
        return b.s - a.s;
    });
    return res.slice(0, limit || 5);
}

// The single result to lift above every section, if one clearly stands out
// for this query: affinity >= MIN and at least RATIO x the runner-up.
var TOP_MIN = 1.2;
var TOP_RATIO = 1.5;
function topHitKey(query, presentKeys) {
    var aff = affinities(query);
    var best = "", b1 = 0, b2 = 0;
    for (var i = 0; i < presentKeys.length; i++) {
        var a = aff[presentKeys[i]] || 0;
        if (a > b1) {
            b2 = b1;
            b1 = a;
            best = presentKeys[i];
        } else if (a > b2) {
            b2 = a;
        }
    }
    return (b1 >= TOP_MIN && b1 >= b2 * TOP_RATIO) ? best : "";
}
