.pragma library

// Pure text transforms behind the b64 / url / jwt / ts launcher plugins.
// No Qt APIs in here, so the file can be exercised with plain node (strip the
// pragma line); DevTool.qml turns the results into launcher items.
//
// Every tool takes the input string and returns a list of rows:
//   { name, comment, value, icon }   -- value is what Enter copies
// or an empty list when the input means nothing to it.

// ── UTF-8 / base64, by hand ───────────────────────────────────────────
// Qt.btoa/atob work on Latin-1 strings and would mangle anything else.

function utf8Encode(str) {
    var out = [];
    for (var i = 0; i < str.length; i++) {
        var c = str.charCodeAt(i);
        if (c >= 0xd800 && c <= 0xdbff && i + 1 < str.length) {
            var d = str.charCodeAt(i + 1);
            if (d >= 0xdc00 && d <= 0xdfff) {
                c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00);
                i++;
            }
        }
        if (c < 0x80) {
            out.push(c);
        } else if (c < 0x800) {
            out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
        } else if (c < 0x10000) {
            out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
        } else {
            out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
        }
    }
    return out;
}

// Strict: returns null on malformed UTF-8 so binary is reported as binary
// rather than as a screenful of replacement characters.
function utf8Decode(bytes) {
    var out = "";
    for (var i = 0; i < bytes.length;) {
        var b = bytes[i];
        var cp, n;
        if (b < 0x80) {
            cp = b; n = 0;
        } else if ((b & 0xe0) === 0xc0) {
            cp = b & 0x1f; n = 1;
        } else if ((b & 0xf0) === 0xe0) {
            cp = b & 0x0f; n = 2;
        } else if ((b & 0xf8) === 0xf0) {
            cp = b & 0x07; n = 3;
        } else {
            return null;
        }
        for (var k = 1; k <= n; k++) {
            var cb = bytes[i + k];
            if (cb === undefined || (cb & 0xc0) !== 0x80)
                return null;
            cp = (cp << 6) | (cb & 0x3f);
        }
        i += n + 1;
        if (cp > 0xffff) {
            cp -= 0x10000;
            out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
        } else {
            out += String.fromCharCode(cp);
        }
    }
    return out;
}

var B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

function bytesToB64(bytes, urlSafe) {
    var out = "";
    for (var i = 0; i < bytes.length; i += 3) {
        var n = (bytes[i] << 16) | ((bytes[i + 1] || 0) << 8) | (bytes[i + 2] || 0);
        out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63];
        out += i + 1 < bytes.length ? B64[(n >> 6) & 63] : "=";
        out += i + 2 < bytes.length ? B64[n & 63] : "=";
    }
    if (urlSafe)
        out = out.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    return out;
}

// Accepts standard and URL-safe alphabets, with or without padding, and
// ignores whitespace (wrapped base64 from PEM files, emails, ...).
function b64ToBytes(str) {
    var s = str.replace(/\s+/g, "").replace(/-/g, "+").replace(/_/g, "/");
    if (!/^[A-Za-z0-9+/]*={0,2}$/.test(s))
        return null;
    s = s.replace(/=+$/, "");
    if (s.length % 4 === 1)
        return null;
    var out = [];
    var buf = 0, bits = 0;
    for (var i = 0; i < s.length; i++) {
        buf = (buf << 6) | B64.indexOf(s[i]);
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out.push((buf >> bits) & 0xff);
        }
    }
    return out;
}

function hexPreview(bytes, max) {
    var parts = [];
    for (var i = 0; i < Math.min(bytes.length, max); i++)
        parts.push((bytes[i] < 16 ? "0" : "") + bytes[i].toString(16));
    return parts.join(" ") + (bytes.length > max ? " …" : "");
}

// ── b64 ──────────────────────────────────────────────────────────────
function b64(input) {
    if (!input)
        return [];
    var rows = [];

    // Decode first when the input plausibly *is* base64: that's the usual
    // reason to paste something opaque in here.
    // Only line breaks are stripped (wrapped PEM / email base64): a space
    // means prose, and "hello world" must not "decode" to binary noise.
    var compact = input.replace(/[\r\n]+/g, "");
    if (compact.length >= 4 && /^[A-Za-z0-9+/_-]+={0,2}$/.test(compact)) {
        var bytes = b64ToBytes(compact);
        if (bytes && bytes.length > 0) {
            var text = utf8Decode(bytes);
            // Any short word is technically valid base64; only claim binary
            // when it is shaped like real base64 (padded or a multiple of 4).
            var shaped = compact.length >= 8 && (/=$/.test(compact) || compact.length % 4 === 0);
            if (text !== null && !/[\x00-\x08\x0e-\x1f\x7f]/.test(text)) {
                rows.push({ name: text, comment: "Decoded from base64 · " + bytes.length + " bytes", value: text, icon: "lock_open" });
            } else if (shaped) {
                var hex = hexPreview(bytes, 4096);
                rows.push({ name: hexPreview(bytes, 24), comment: "Decoded from base64 · binary, " + bytes.length + " bytes · copies hex", value: hex, icon: "memory" });
            }
        }
    }

    var enc = utf8Encode(input);
    rows.push({ name: bytesToB64(enc, false), comment: "Base64 encoded", value: bytesToB64(enc, false), icon: "lock" });
    rows.push({ name: bytesToB64(enc, true), comment: "Base64url encoded (no padding, JWT / URL safe)", value: bytesToB64(enc, true), icon: "link" });
    return rows;
}

// ── url ──────────────────────────────────────────────────────────────
function url(input) {
    if (!input)
        return [];
    var rows = [];

    if (/%[0-9a-fA-F]{2}|\+/.test(input)) {
        try {
            var dec = decodeURIComponent(input.replace(/\+/g, " "));
            if (dec !== input)
                rows.push({ name: dec, comment: "URL decoded (+ read as space)", value: dec, icon: "link_off" });
        } catch (e) {
            // Malformed escape: not something we can decode; fall through to encode.
        }
    }

    var comp = encodeURIComponent(input);
    rows.push({ name: comp, comment: "URL encoded · component (query value, path segment)", value: comp, icon: "link" });
    var full = encodeURI(input);
    if (full !== comp)
        rows.push({ name: full, comment: "URL encoded · full URL (keeps : / ? & =)", value: full, icon: "public" });

    // A full URL on its way in: break the query string out, one row per
    // parameter, decoded -- the thing you actually wanted to read.
    var q = input.indexOf("?");
    if (/^[a-z][a-z0-9+.-]*:\/\//i.test(input) && q !== -1) {
        var qs = input.substring(q + 1).split("#")[0];
        var pairs = qs.split("&");
        for (var i = 0; i < pairs.length && i < 30; i++) {
            if (!pairs[i])
                continue;
            var eq = pairs[i].indexOf("=");
            var k = eq === -1 ? pairs[i] : pairs[i].substring(0, eq);
            var v = eq === -1 ? "" : pairs[i].substring(eq + 1);
            try {
                k = decodeURIComponent(k.replace(/\+/g, " "));
                v = decodeURIComponent(v.replace(/\+/g, " "));
            } catch (e2) {}
            rows.push({ name: k + " = " + v, comment: "Query parameter · copies the value", value: v, icon: "tune" });
        }
    }
    return rows;
}

// ── time helpers ─────────────────────────────────────────────────────
function pad(n, w) {
    var s = String(Math.abs(Math.trunc(n)));
    while (s.length < (w || 2))
        s = "0" + s;
    return s;
}

function localString(d) {
    var off = -d.getTimezoneOffset();
    return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate()) + " " + pad(d.getHours()) + ":" + pad(d.getMinutes()) + ":" + pad(d.getSeconds()) + " (UTC" + (off >= 0 ? "+" : "-") + pad(off / 60) + ":" + pad(off % 60) + ")";
}

var DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

function relative(ms, now) {
    var diff = ms - now;
    var abs = Math.abs(diff) / 1000;
    var unit, n;
    if (abs < 45)
        return diff >= 0 ? "in a few seconds" : "just now";
    if (abs < 5400) { n = Math.round(abs / 60); unit = "minute"; }
    else if (abs < 129600) { n = Math.round(abs / 3600); unit = "hour"; }
    else if (abs < 86400 * 45) { n = Math.round(abs / 86400); unit = "day"; }
    else if (abs < 86400 * 548) { n = Math.round(abs / (86400 * 30.44)); unit = "month"; }
    else { n = Math.round(abs / (86400 * 365.25) * 10) / 10; unit = "year"; }
    var s = n + " " + unit + (n === 1 ? "" : "s");
    return diff >= 0 ? "in " + s : s + " ago";
}

// Unix seconds / ms / µs / ns told apart by magnitude; anything else goes
// through Date.parse (ISO 8601, RFC 2822, "2026-09-26 17:00", ...).
function parseTime(input, now) {
    var s = (input || "").trim();
    if (s === "" || s.toLowerCase() === "now")
        return { ms: now, how: "now" };
    if (/^-?\d+(\.\d+)?$/.test(s)) {
        var v = parseFloat(s);
        var a = Math.abs(v);
        if (a < 1e11) return { ms: v * 1000, how: "Unix seconds" };
        if (a < 1e14) return { ms: v, how: "Unix milliseconds" };
        if (a < 1e17) return { ms: v / 1000, how: "Unix microseconds" };
        return { ms: v / 1e6, how: "Unix nanoseconds" };
    }
    // "2026-09-26 17:00" is not ISO to every engine -- give it the T.
    var iso = s.replace(/^(\d{4}-\d{2}-\d{2})[ ](\d)/, "$1T$2");
    var p = Date.parse(iso);
    if (isNaN(p))
        p = Date.parse(s);
    if (isNaN(p))
        return null;
    return { ms: p, how: "date string" };
}

// ── ts ───────────────────────────────────────────────────────────────
function ts(input, now) {
    now = now || Date.now();
    var t = parseTime(input, now);
    if (!t)
        return [];
    var d = new Date(t.ms);
    if (isNaN(d.getTime()))
        return [];
    var secs = Math.floor(t.ms / 1000);
    var rel = t.how === "now" ? "now" : relative(t.ms, now);
    var from = t.how === "now" ? "" : " · from " + t.how;
    return [
        { name: DAYS[d.getDay()] + " " + localString(d), comment: "Local time · " + rel + from, value: localString(d).replace(/ \(UTC.*$/, ""), icon: "schedule" },
        { name: d.toISOString(), comment: "ISO 8601 · UTC", value: d.toISOString(), icon: "public" },
        { name: String(secs), comment: "Unix seconds", value: String(secs), icon: "timer" },
        { name: String(Math.floor(t.ms)), comment: "Unix milliseconds", value: String(Math.floor(t.ms)), icon: "timer" }
    ];
}

// ── jwt ──────────────────────────────────────────────────────────────
function jwtPart(seg) {
    var bytes = b64ToBytes(seg);
    if (!bytes)
        return null;
    var text = utf8Decode(bytes);
    if (text === null)
        return null;
    try {
        return JSON.parse(text);
    } catch (e) {
        return null;
    }
}

function jwt(input, now) {
    now = now || Date.now();
    var token = (input || "").trim().replace(/^Bearer\s+/i, "");
    var parts = token.split(".");
    if (parts.length < 2)
        return [];
    var header = jwtPart(parts[0]);
    var payload = jwtPart(parts[1]);
    if (!header || !payload)
        return [];

    var rows = [];
    var claim = function (key, label) {
        var v = payload[key];
        if (typeof v !== "number")
            return;
        var ms = v * 1000;
        var when = localString(new Date(ms));
        var rel = relative(ms, now);
        var name = label + " " + rel;
        if (key === "exp")
            name = (ms < now ? "EXPIRED " : "Expires ") + rel;
        rows.push({ name: name, comment: label + " · " + when + " · " + key + "=" + v, value: new Date(ms).toISOString(), icon: key === "exp" ? (ms < now ? "error" : "hourglass_bottom") : "schedule" });
    };
    claim("exp", "Expires");

    var payloadPretty = JSON.stringify(payload, null, 2);
    rows.push({ name: JSON.stringify(payload), comment: "Payload · copies pretty JSON", value: payloadPretty, icon: "data_object" });
    rows.push({ name: JSON.stringify(header), comment: "Header · alg " + (header.alg || "?") + (parts.length < 3 || !parts[2] ? " · UNSIGNED" : " · signature not verified"), value: JSON.stringify(header, null, 2), icon: "badge" });

    claim("iat", "Issued");
    claim("nbf", "Valid from");

    var strKeys = ["sub", "iss", "aud", "name", "email", "preferred_username", "unique_name", "role", "roles", "scope", "scp", "azp", "client_id", "tid", "oid"];
    for (var i = 0; i < strKeys.length; i++) {
        var k = strKeys[i];
        if (payload[k] === undefined)
            continue;
        var val = Array.isArray(payload[k]) ? payload[k].join(", ") : String(payload[k]);
        rows.push({ name: k + ": " + val, comment: "Claim · copies the value", value: val, icon: "label" });
    }
    return rows;
}
