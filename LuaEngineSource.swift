import Foundation

// ============================================================
// このファイルは自動生成です (Lua → JavaScript 変換器 + Lua 標準ライブラリ + Editor API)。
// JavaScriptCore の中で動かします。手で直さず、元の JS を直してから作り直してください。
// ============================================================
enum LuaEngineSource {
    static let js = ##"""
(function (root) {
'use strict';
// ============================================================
// Lua -> JavaScript 変換器 (字句解析 / 構文解析)
// ============================================================
class LuaSyntaxError extends Error {}

const KEYWORDS = new Set(['and', 'break', 'do', 'else', 'elseif', 'end', 'false', 'for', 'function', 'goto', 'if', 'in',
  'local', 'nil', 'not', 'or', 'repeat', 'return', 'then', 'true', 'until', 'while']);

function lexAll(src, chunk) {
  const toks = [];
  const n = src.length;
  let i = 0, line = 1;
  const fail = (msg) => { throw new LuaSyntaxError(chunk + ':' + line + ': ' + msg); };
  const isDigit = (c) => c !== undefined && c >= '0' && c <= '9';
  const isAlpha = (c) => c !== undefined && ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c === '_');
  const isHex = (c) => isDigit(c) || (c !== undefined && ((c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')));

  if (src.charCodeAt(0) === 35) { while (i < n && src[i] !== '\n') i++; }   // #! 行

  function longLevel(p) {          // src[p] === '[' のとき、[==[ の = の数。長い括弧でなければ -1
    let q = p + 1, lvl = 0;
    while (src[q] === '=') { lvl++; q++; }
    return src[q] === '[' ? lvl : -1;
  }
  function readLong(p, lvl, what) {
    let q = p + lvl + 2;
    if (src[q] === '\n') { q++; line++; }
    const close = ']' + '='.repeat(lvl) + ']';
    const e = src.indexOf(close, q);
    if (e < 0) fail('unfinished long ' + what);
    const s = src.slice(q, e);
    for (let k = 0; k < s.length; k++) if (s[k] === '\n') line++;
    i = e + close.length;
    return s;
  }

  while (i < n) {
    const c = src[i];
    if (c === '\n') { line++; i++; continue; }
    if (c === ' ' || c === '\t' || c === '\r' || c === '\f' || c === '\v') { i++; continue; }
    if (c === '-' && src[i + 1] === '-') {
      i += 2;
      if (src[i] === '[') {
        const lvl = longLevel(i);
        if (lvl >= 0) { readLong(i, lvl, 'comment'); continue; }
      }
      while (i < n && src[i] !== '\n') i++;
      continue;
    }
    if (isAlpha(c)) {
      let j = i + 1;
      while (j < n && (isAlpha(src[j]) || isDigit(src[j]))) j++;
      const w = src.slice(i, j);
      if (KEYWORDS.has(w)) toks.push({ t: w, v: w, l: line });
      else toks.push({ t: 'name', v: w, l: line });
      i = j;
      continue;
    }
    if (isDigit(c) || (c === '.' && isDigit(src[i + 1]))) {
      let j = i, val;
      if (c === '0' && (src[i + 1] === 'x' || src[i + 1] === 'X')) {
        j = i + 2;
        let mant = 0, any = false, exp = 0;
        while (isHex(src[j])) { mant = mant * 16 + parseInt(src[j], 16); j++; any = true; }
        if (src[j] === '.') {
          j++;
          while (isHex(src[j])) { mant = mant * 16 + parseInt(src[j], 16); exp -= 4; j++; any = true; }
        }
        if (!any) fail('malformed number');
        if (src[j] === 'p' || src[j] === 'P') {
          j++;
          let sign = 1;
          if (src[j] === '+' || src[j] === '-') { if (src[j] === '-') sign = -1; j++; }
          let e = 0, anyE = false;
          while (isDigit(src[j])) { e = e * 10 + (src.charCodeAt(j) - 48); j++; anyE = true; }
          if (!anyE) fail('malformed number');
          exp += sign * e;
        }
        val = mant * Math.pow(2, exp);
      } else {
        while (isDigit(src[j])) j++;
        if (src[j] === '.' && src[j + 1] !== '.') { j++; while (isDigit(src[j])) j++; }
        if (src[j] === 'e' || src[j] === 'E') {
          let k = j + 1;
          if (src[k] === '+' || src[k] === '-') k++;
          if (!isDigit(src[k])) fail('malformed number');
          while (isDigit(src[k])) k++;
          j = k;
        }
        val = Number(src.slice(i, j));
      }
      if (isAlpha(src[j])) fail("malformed number near '" + src.slice(i, j + 1) + "'");
      toks.push({ t: 'number', v: val, l: line });
      i = j;
      continue;
    }
    if (c === '"' || c === "'") {
      const q = c;
      i++;
      let out = '';
      for (;;) {
        if (i >= n) fail('unfinished string');
        const ch = src[i];
        if (ch === q) { i++; break; }
        if (ch === '\n') fail('unfinished string');
        if (ch === '\\') {
          i++;
          const e = src[i];
          if (e === 'n') { out += '\n'; i++; }
          else if (e === 't') { out += '\t'; i++; }
          else if (e === 'r') { out += '\r'; i++; }
          else if (e === 'a') { out += '\x07'; i++; }
          else if (e === 'b') { out += '\b'; i++; }
          else if (e === 'f') { out += '\f'; i++; }
          else if (e === 'v') { out += '\v'; i++; }
          else if (e === '\\') { out += '\\'; i++; }
          else if (e === '"') { out += '"'; i++; }
          else if (e === "'") { out += "'"; i++; }
          else if (e === '\n') { out += '\n'; line++; i++; }
          else if (e === 'x') {
            const h = src.substr(i + 1, 2);
            if (!/^[0-9a-fA-F]{2}$/.test(h)) fail('hexadecimal digit expected');
            out += String.fromCharCode(parseInt(h, 16));
            i += 3;
          } else if (e === 'z') {
            i++;
            while (i < n && /\s/.test(src[i])) { if (src[i] === '\n') line++; i++; }
          } else if (e === 'u') {
            const m = /^\{([0-9a-fA-F]+)\}/.exec(src.slice(i + 1, i + 12));
            if (!m) fail('missing { in \\u{xxxx}');
            out += String.fromCodePoint(parseInt(m[1], 16));
            i += 1 + m[0].length;
          } else if (isDigit(e)) {
            let d = 0, k = 0;
            while (k < 3 && isDigit(src[i])) { d = d * 10 + (src.charCodeAt(i) - 48); i++; k++; }
            if (d > 255) fail('decimal escape too large');
            out += String.fromCharCode(d);
          } else fail('invalid escape sequence');
          continue;
        }
        out += ch;
        i++;
      }
      toks.push({ t: 'string', v: out, l: line });
      continue;
    }
    if (c === '[') {
      const lvl = longLevel(i);
      if (lvl >= 0) {
        const startLine = line;
        const s = readLong(i, lvl, 'string');
        toks.push({ t: 'string', v: s, l: startLine });
        continue;
      }
    }
    const three = src.substr(i, 3);
    if (three === '...') { toks.push({ t: '...', v: '...', l: line }); i += 3; continue; }
    const two = src.substr(i, 2);
    if (two === '==' || two === '~=' || two === '<=' || two === '>=' || two === '..' || two === '::' ||
        two === '//' || two === '<<' || two === '>>') {
      toks.push({ t: two, v: two, l: line });
      i += 2;
      continue;
    }
    if ('+-*/%^#&~|<>=(){}[];:,.'.indexOf(c) >= 0) {
      toks.push({ t: c, v: c, l: line });
      i++;
      continue;
    }
    fail("unexpected symbol near '" + c + "'");
  }
  toks.push({ t: 'eof', v: '<eof>', l: line });
  return toks;
}

const BINPRI = new Map([
  ['or', [1, 1]], ['and', [2, 2]],
  ['<', [3, 3]], ['>', [3, 3]], ['<=', [3, 3]], ['>=', [3, 3]], ['~=', [3, 3]], ['==', [3, 3]],
  ['|', [4, 4]], ['~', [5, 5]], ['&', [6, 6]], ['<<', [7, 7]], ['>>', [7, 7]],
  ['..', [9, 8]], ['+', [10, 10]], ['-', [10, 10]],
  ['*', [11, 11]], ['/', [11, 11]], ['//', [11, 11]], ['%', [11, 11]],
  ['^', [14, 13]]
]);
const UNARY_PRI = 12;

function parseLua(src, chunk) {
  src = src.replace(/\r\n?/g, '\n');
  if (src.charCodeAt(0) === 0xFEFF) src = src.slice(1);
  const toks = lexAll(src, chunk);
  let p = 0;

  const cur = () => toks[p];
  const next = () => toks[p++];
  const err = (msg) => {
    const t = toks[p];
    throw new LuaSyntaxError(chunk + ':' + t.l + ': ' + msg + " near '" + (t.t === 'string' ? t.v : t.v) + "'");
  };
  const check = (t) => toks[p].t === t;
  const accept = (t) => { if (toks[p].t === t) { p++; return true; } return false; };
  const expect = (t, what) => { if (toks[p].t !== t) err("'" + (what || t) + "' expected"); return toks[p++]; };
  const expectName = () => { if (toks[p].t !== 'name') err('<name> expected'); return toks[p++].v; };
  const blockEnd = () => {
    const t = toks[p].t;
    return t === 'else' || t === 'elseif' || t === 'end' || t === 'until' || t === 'eof';
  };

  function parseBlock() {
    const stmts = [];
    while (!blockEnd()) {
      if (check('return')) {
        stmts.push(parseReturn());
        break;
      }
      const s = parseStatement();
      if (s) stmts.push(s);
    }
    return stmts;
  }

  function parseReturn() {
    const line = next().l;
    let exprs = [];
    if (!blockEnd() && !check(';')) exprs = parseExprList();
    accept(';');
    return { k: 'Return', exprs, line };
  }

  function parseStatement() {
    const line = cur().l;
    switch (cur().t) {
      case ';': next(); return null;
      case 'if': return parseIf();
      case 'while': {
        next();
        const cond = parseExpr();
        expect('do');
        const body = parseBlock();
        expect('end');
        return { k: 'While', cond, body, line };
      }
      case 'do': {
        next();
        const body = parseBlock();
        expect('end');
        return { k: 'Do', body, line };
      }
      case 'for': return parseFor();
      case 'repeat': {
        next();
        const body = parseBlock();
        expect('until');
        const cond = parseExpr();
        return { k: 'Repeat', body, cond, line };
      }
      case 'function': {
        next();
        // funcname: Name {'.' Name} [':' Name]
        let target = { k: 'Name', name: expectName(), line };
        let isMethod = false;
        while (check('.') || check(':')) {
          const sep = next().t;
          const key = expectName();
          target = { k: 'Index', obj: target, key: { k: 'Str', v: key }, line };
          if (sep === ':') { isMethod = true; break; }
        }
        const f = parseFuncBody(isMethod, line);
        return { k: 'Assign', targets: [target], exprs: [f], line };
      }
      case 'local': {
        next();
        if (accept('function')) {
          const name = expectName();
          const f = parseFuncBody(false, line);
          return { k: 'LocalFunction', name, func: f, line };
        }
        const names = [];
        do {
          names.push(expectName());
          if (accept('<')) { expectName(); expect('>'); }       // <const> / <close> は読み飛ばす
        } while (accept(','));
        let exprs = [];
        if (accept('=')) exprs = parseExprList();
        return { k: 'Local', names, exprs, line };
      }
      case 'return': return parseReturn();
      case 'break': next(); return { k: 'Break', line };
      case 'goto': {
        next();
        return { k: 'Goto', name: expectName(), line };
      }
      case '::': {
        next();
        const name = expectName();
        expect('::');
        return { k: 'Label', name, line };
      }
      default: return parseExprStat();
    }
  }

  function parseIf() {
    const line = cur().l;
    const clauses = [];
    let orelse = null;
    next();
    let cond = parseExpr();
    expect('then');
    clauses.push({ cond, body: parseBlock() });
    for (;;) {
      if (check('elseif')) {
        next();
        cond = parseExpr();
        expect('then');
        clauses.push({ cond, body: parseBlock() });
      } else if (check('else')) {
        next();
        orelse = parseBlock();
        expect('end');
        break;
      } else {
        expect('end');
        break;
      }
    }
    return { k: 'If', clauses, orelse, line };
  }

  function parseFor() {
    const line = next().l;
    const n1 = expectName();
    if (check('=')) {
      next();
      const a = parseExpr();
      expect(',');
      const b = parseExpr();
      let c = null;
      if (accept(',')) c = parseExpr();
      expect('do');
      const body = parseBlock();
      expect('end');
      return { k: 'NumFor', name: n1, a, b, c, body, line };
    }
    const names = [n1];
    while (accept(',')) names.push(expectName());
    expect('in');
    const exprs = parseExprList();
    expect('do');
    const body = parseBlock();
    expect('end');
    return { k: 'GenFor', names, exprs, body, line };
  }

  function parseExprStat() {
    const line = cur().l;
    const e = parseSuffixed();
    if (check('=') || check(',')) {
      const targets = [e];
      while (accept(',')) targets.push(parseSuffixed());
      expect('=');
      const exprs = parseExprList();
      for (const t of targets) {
        if (t.k !== 'Name' && t.k !== 'Index') err('syntax error');
      }
      return { k: 'Assign', targets, exprs, line };
    }
    if (e.k !== 'Call' && e.k !== 'MCall') err('syntax error');
    return { k: 'CallStat', call: e, line };
  }

  function parseExprList() {
    const list = [parseExpr()];
    while (accept(',')) list.push(parseExpr());
    return list;
  }

  function parseExpr() { return parseSub(0); }

  function parseSub(limit) {
    let left;
    const t = cur().t;
    if (t === 'not' || t === '-' || t === '#' || t === '~') {
      const line = next().l;
      const e = parseSub(UNARY_PRI);
      if (t === '-' && e.k === 'Num') left = { k: 'Num', v: -e.v };
      else left = { k: 'Un', op: t, e, line };
    } else {
      left = parseSimple();
    }
    for (;;) {
      const op = cur().t;
      const pri = BINPRI.get(op);
      if (!pri || pri[0] <= limit) break;
      const line = next().l;
      const right = parseSub(pri[1]);
      left = { k: 'Bin', op, l: left, r: right, line };
    }
    return left;
  }

  function parseSimple() {
    const t = cur();
    switch (t.t) {
      case 'number': next(); return { k: 'Num', v: t.v };
      case 'string': next(); return { k: 'Str', v: t.v };
      case 'nil': next(); return { k: 'Nil' };
      case 'true': next(); return { k: 'True' };
      case 'false': next(); return { k: 'False' };
      case '...': next(); return { k: 'Vararg', line: t.l };
      case '{': return parseTable();
      case 'function': { next(); return parseFuncBody(false, t.l); }
      default: return parseSuffixed();
    }
  }

  function parsePrimary() {
    const t = cur();
    if (t.t === 'name') { next(); return { k: 'Name', name: t.v, line: t.l }; }
    if (t.t === '(') {
      next();
      const e = parseExpr();
      expect(')');
      return { k: 'Paren', e };
    }
    err('unexpected symbol');
  }

  function parseSuffixed() {
    let e = parsePrimary();
    for (;;) {
      const t = cur();
      switch (t.t) {
        case '.': {
          next();
          const name = expectName();
          e = { k: 'Index', obj: e, key: { k: 'Str', v: name }, line: t.l };
          break;
        }
        case '[': {
          next();
          const key = parseExpr();
          expect(']');
          e = { k: 'Index', obj: e, key, line: t.l };
          break;
        }
        case ':': {
          next();
          const name = expectName();
          const args = parseArgs();
          e = { k: 'MCall', obj: e, name, args, line: t.l };
          break;
        }
        case '(': case 'string': case '{': {
          const args = parseArgs();
          e = { k: 'Call', f: e, args, line: t.l };
          break;
        }
        default: return e;
      }
    }
  }

  function parseArgs() {
    const t = cur();
    if (t.t === 'string') { next(); return [{ k: 'Str', v: t.v }]; }
    if (t.t === '{') return [parseTable()];
    if (t.t === '(') {
      next();
      if (accept(')')) return [];
      const list = parseExprList();
      expect(')');
      return list;
    }
    err('function arguments expected');
  }

  function parseTable() {
    const line = expect('{').l;
    const items = [];
    while (!check('}')) {
      if (check('[')) {
        next();
        const key = parseExpr();
        expect(']');
        expect('=');
        items.push({ key, val: parseExpr() });
      } else if (check('name') && toks[p + 1].t === '=') {
        const name = next().v;
        next();
        items.push({ key: { k: 'Str', v: name }, val: parseExpr() });
      } else {
        items.push({ key: null, val: parseExpr() });
      }
      if (!accept(',') && !accept(';')) break;
    }
    expect('}');
    return { k: 'Table', items, line };
  }

  function parseFuncBody(isMethod, line) {
    const params = [];
    let vararg = false;
    if (isMethod) params.push('self');
    expect('(');
    if (!check(')')) {
      do {
        if (check('...')) { next(); vararg = true; break; }
        params.push(expectName());
      } while (accept(','));
    }
    expect(')');
    const body = parseBlock();
    expect('end');
    return { k: 'Func', params, vararg, body, line };
  }

  const body = parseBlock();
  if (!check('eof')) err("'<eof>' expected");
  return { k: 'Chunk', body };
}

// ============================================================
// コード生成: Lua AST -> JavaScript ソース
//   Lua の関数は「引数を並べて受け取り、戻り値の配列を返す」JS関数になる
//   nil = undefined / 真偽値・数値・文字列は JS のまま / テーブルは LuaTable
// ============================================================
function generateJS(ast, chunk) {
  let uid = 0;
  let scope = null;
  let fn = null;

  const fail = (msg, line) => { throw new LuaSyntaxError(chunk + ':' + (line || 0) + ': ' + msg); };

  function pushScope() { scope = { vars: new Map(), parent: scope }; }
  function popScope() { scope = scope.parent; }
  function declare(name) {
    const js = name + '_' + (++uid);
    scope.vars.set(name, js);
    return js;
  }
  function lookup(name) {
    for (let s = scope; s; s = s.parent) {
      const v = s.vars.get(name);
      if (v !== undefined) return v;
    }
    return undefined;
  }
  function newTemp() {
    const t = '$t' + (++uid);
    fn.temps.push(t);
    return t;
  }

  const isMulti = (e) => e.k === 'Call' || e.k === 'MCall' || e.k === 'Vararg';
  const q = (s) => JSON.stringify(s);

  // ---------- 式 ----------
  function callRaw(e) {
    if (e.k === 'Call') {
      const parts = [gx(e.f)].concat(argList(e.args));
      return 'call(' + parts.join(',') + ')';
    }
    const parts = [gx(e.obj), q(e.name)].concat(argList(e.args));
    return 'callm(' + parts.join(',') + ')';
  }

  function argList(args) {
    const out = [];
    for (let i = 0; i < args.length; i++) {
      const a = args[i];
      if (i === args.length - 1 && isMulti(a)) out.push(multiSpread(a));
      else out.push(gx(a));
    }
    return out;
  }

  function multiSpread(e) {
    if (e.k === 'Vararg') return '...$va';
    return '...' + callRaw(e);
  }

  // 複数の式 -> JS の配列リテラルの中身 (最後が多値ならその値を全部並べる)
  function exprListItems(exprs) {
    return argList(exprs).join(',');
  }

  // 単一の値になる式
  function gx(e) {
    switch (e.k) {
      case 'Nil': return 'undefined';
      case 'True': return 'true';
      case 'False': return 'false';
      case 'Num': {
        const v = e.v;
        if (v === Infinity) return 'Infinity';
        if (v === -Infinity) return '(-Infinity)';
        if (v !== v) return 'NaN';
        return v < 0 || Object.is(v, -0) ? '(' + String(v) + ')' : String(v);
      }
      case 'Str': return q(e.v);
      case 'Vararg':
        if (!fn.vararg) fail("cannot use '...' outside a vararg function", e.line);
        return '$va[0]';
      case 'Func': return genFunc(e);
      case 'Name': {
        const js = lookup(e.name);
        if (js !== undefined) return js;
        return 'index(G,' + q(e.name) + ')';
      }
      case 'Index': return 'index(' + gx(e.obj) + ',' + gx(e.key) + ')';
      case 'Call': case 'MCall': return callRaw(e) + '[0]';
      case 'Paren': return gx(e.e);
      case 'Table': return genTable(e);
      case 'Un': {
        if (e.op === 'not') return '!' + gc(e.e);
        const a = gx(e.e);
        if (e.op === '-') return 'unm(' + a + ')';
        if (e.op === '#') return 'len(' + a + ')';
        if (e.op === '~') return 'bnot(' + a + ')';
        break;
      }
      case 'Bin': return genBin(e);
    }
    throw new Error('internal: unknown expr ' + e.k);
  }

  function genBin(e) {
    const op = e.op;
    if (op === 'and') {
      const t = newTemp();
      return '(T(' + t + '=' + gx(e.l) + ')?' + gx(e.r) + ':' + t + ')';
    }
    if (op === 'or') {
      const t = newTemp();
      return '(T(' + t + '=' + gx(e.l) + ')?' + t + ':' + gx(e.r) + ')';
    }
    const a = gx(e.l), b = gx(e.r);
    switch (op) {
      case '+': return 'add(' + a + ',' + b + ')';
      case '-': return 'sub(' + a + ',' + b + ')';
      case '*': return 'mul(' + a + ',' + b + ')';
      case '/': return 'div(' + a + ',' + b + ')';
      case '%': return 'mod(' + a + ',' + b + ')';
      case '^': return 'pow(' + a + ',' + b + ')';
      case '//': return 'idiv(' + a + ',' + b + ')';
      case '..': return 'concat(' + a + ',' + b + ')';
      case '==': return 'eq(' + a + ',' + b + ')';
      case '~=': return '!eq(' + a + ',' + b + ')';
      case '<': return 'lt(' + a + ',' + b + ')';
      case '<=': return 'le(' + a + ',' + b + ')';
      case '>': return 'gt(' + a + ',' + b + ')';
      case '>=': return 'ge(' + a + ',' + b + ')';
      case '&': return 'band(' + a + ',' + b + ')';
      case '|': return 'bor(' + a + ',' + b + ')';
      case '~': return 'bxor(' + a + ',' + b + ')';
      case '<<': return 'shl(' + a + ',' + b + ')';
      case '>>': return 'shr(' + a + ',' + b + ')';
    }
    throw new Error('internal: unknown binop ' + op);
  }

  // 条件として使う式 (JS の真偽値になる)
  function gc(e) {
    switch (e.k) {
      case 'True': return 'true';
      case 'Nil': case 'False': return 'false';
      case 'Paren': return gc(e.e);
      case 'Un': if (e.op === 'not') return '!' + gc(e.e); break;
      case 'Bin':
        if (e.op === 'and') return '(' + gc(e.l) + '&&' + gc(e.r) + ')';
        if (e.op === 'or') return '(' + gc(e.l) + '||' + gc(e.r) + ')';
        if (e.op === '==' || e.op === '~=' || e.op === '<' || e.op === '<=' || e.op === '>' || e.op === '>=') return gx(e);
        break;
    }
    return 'T(' + gx(e) + ')';
  }

  function genTable(e) {
    const pos = [];
    const kv = [];
    const items = e.items;
    for (let i = 0; i < items.length; i++) {
      const it = items[i];
      if (it.key === null) {
        if (i === items.length - 1 && isMulti(it.val)) pos.push(multiSpread(it.val));
        else pos.push(gx(it.val));
      } else {
        kv.push(gx(it.key), gx(it.val));
      }
    }
    if (kv.length === 0 && pos.length === 0) return 'mk()';
    if (kv.length === 0) return 'mk([' + pos.join(',') + '])';
    return 'mk([' + pos.join(',') + '],[' + kv.join(',') + '])';
  }

  function genFunc(f) {
    const saved = fn;
    fn = { temps: [], vararg: f.vararg, loops: [], blocks: [] };
    pushScope();
    const params = f.params.map(declare);
    if (f.vararg) params.push('...$va');
    const body = genBlock(f.body);
    popScope();
    const temps = fn.temps.length ? 'let ' + fn.temps.join(',') + ';' : '';
    fn = saved;
    return 'function(' + params.join(',') + '){' + temps + body + 'return E;}';
  }

  // ---------- 文 ----------
  // goto は「同じブロックか外側のブロックにあるラベルへの前方ジャンプ」だけ対応する
  //  (ラベル手前の文を JS のラベル付きブロックで包み、break ラベル; に変換)
  function genBlock(stmts, tail) {
    pushScope();
    const labels = new Map();
    for (let i = 0; i < stmts.length; i++) {
      const s = stmts[i];
      if (s.k === 'Label') {
        if (labels.has(s.name)) fail("label '" + s.name + "' already defined", s.line);
        labels.set(s.name, { js: 'Lb' + (++uid), passed: false, first: -1, idx: i });
      }
    }
    const ctx = { labels, cur: 0 };
    fn.blocks.push(ctx);
    const parts = [];
    for (let i = 0; i < stmts.length; i++) {
      const s = stmts[i];
      ctx.cur = i;
      if (s.k === 'Label') {
        labels.get(s.name).passed = true;
        parts.push('');
        continue;
      }
      parts.push(genStmt(s));
    }
    fn.blocks.pop();
    const tailCode = tail ? tail() : '';
    popScope();

    // ラベルの手前を JS のラベル付きブロックで包む
    const wraps = [];
    for (const lab of labels.values()) {
      if (lab.first >= 0) wraps.push({ start: lab.first, end: lab.idx, js: lab.js });
    }
    if (wraps.length === 0) return parts.join('') + tailCode;
    wraps.sort((a, b) => a.end - b.end);
    for (let r = 0; r < wraps.length; r++) {       // 食い違う区間は、外側が内側を含むように広げる
      for (let m = 0; m < r; m++) {
        const x = wraps[m], y = wraps[r];
        if (y.start > x.start && y.start < x.end && y.end > x.end) y.start = x.start;
      }
    }
    let out = '';
    for (let i = 0; i <= stmts.length; i++) {
      const closing = wraps.filter((w) => w.end === i).sort((a, b) => b.start - a.start);
      for (let c = 0; c < closing.length; c++) out += '}';
      const opening = wraps.filter((w) => w.start === i).sort((a, b) => b.end - a.end);
      for (const w of opening) out += w.js + ':{';
      if (i < stmts.length) out += parts[i];
    }
    return out + tailCode;
  }

  function nameSet(name, valueCode) {
    const js = lookup(name);
    if (js !== undefined) return js + '=' + valueCode + ';';
    return 'setindex(G,' + q(name) + ',' + valueCode + ');';
  }

  function genStmt(s) {
    const ln = 'R.ln=' + s.line + ';';
    switch (s.k) {
      case 'CallStat': return ln + callRaw(s.call) + ';';
      case 'Local': return ln + genLocal(s);
      case 'LocalFunction': {
        const js = declare(s.name);
        return ln + 'let ' + js + ';' + js + '=' + genFunc(s.func) + ';';
      }
      case 'Assign': return ln + genAssign(s);
      case 'Do': return '{' + genBlock(s.body) + '}';
      case 'If': {
        let out = ln;
        for (let i = 0; i < s.clauses.length; i++) {
          const c = s.clauses[i];
          out += (i === 0 ? 'if(' : 'else if(') + gc(c.cond) + '){' + genBlock(c.body) + '}';
        }
        if (s.orelse) out += 'else{' + genBlock(s.orelse) + '}';
        return out;
      }
      case 'While': {
        const lb = 'Lp' + (++uid);
        fn.loops.push(lb);
        const body = genBlock(s.body);
        fn.loops.pop();
        return ln + lb + ':while(' + gc(s.cond) + '){if(--R.fuel<0)R.poll();' + body + '}';
      }
      case 'Repeat': {
        const lb = 'Lp' + (++uid);
        fn.loops.push(lb);
        const body = genBlock(s.body, () => 'if(' + gc(s.cond) + ')break ' + lb + ';');
        fn.loops.pop();
        return ln + lb + ':while(true){if(--R.fuel<0)R.poll();' + body + '}';
      }
      case 'NumFor': return ln + genNumFor(s);
      case 'GenFor': return ln + genGenFor(s);
      case 'Return': {
        if (s.exprs.length === 1 && isMulti(s.exprs[0])) {
          const e = s.exprs[0];
          if (e.k === 'Vararg') return ln + 'return [...$va];';
          return ln + 'return ' + callRaw(e) + ';';
        }
        return ln + 'return [' + exprListItems(s.exprs) + '];';
      }
      case 'Break': {
        if (fn.loops.length === 0) fail('break outside a loop', s.line);
        return 'break ' + fn.loops[fn.loops.length - 1] + ';';
      }
      case 'Goto': {
        for (let i = fn.blocks.length - 1; i >= 0; i--) {
          const ctx = fn.blocks[i];
          const lab = ctx.labels.get(s.name);
          if (lab) {
            if (lab.passed) fail("backward 'goto' is not supported (label '" + s.name + "')", s.line);
            if (lab.first < 0) lab.first = ctx.cur;
            return 'break ' + lab.js + ';';
          }
        }
        fail("no visible label '" + s.name + "' for goto", s.line);
        break;
      }
    }
    throw new Error('internal: unknown stmt ' + s.k);
  }

  function genLocal(s) {
    const names = s.names, exprs = s.exprs;
    // 右辺は、新しい名前を宣言する前の scope で作る
    const simple = names.length === exprs.length;
    if (exprs.length === 0) {
      const js = names.map(declare);
      return 'let ' + js.join(',') + ';';
    }
    if (simple) {
      const codes = exprs.map(gx);
      const js = names.map(declare);
      let out = 'let ';
      out += js.map((n, i) => n + '=' + codes[i]).join(',') + ';';
      return out;
    }
    const items = exprListItems(exprs);
    const js = names.map(declare);
    return 'let [' + js.join(',') + ']=[' + items + '];';
  }

  function genAssign(s) {
    const targets = s.targets, exprs = s.exprs;
    if (targets.length === 1 && exprs.length === 1) {
      return assignTo(targets[0], gx(exprs[0]));
    }
    const id = ++uid;
    let out = '{';
    // 添字つきの代入先は、右辺を評価する前に表と添字を評価しておく
    const pre = [];
    targets.forEach((t, i) => {
      if (t.k === 'Index') {
        pre.push({ o: '$o' + id + '_' + i, k: '$k' + id + '_' + i });
        out += 'const $o' + id + '_' + i + '=' + gx(t.obj) + ',$k' + id + '_' + i + '=' + gx(t.key) + ';';
      } else pre.push(null);
    });
    out += 'const $s' + id + '=[' + exprListItems(exprs) + '];';
    targets.forEach((t, i) => {
      const v = '$s' + id + '[' + i + ']';
      if (t.k === 'Index') out += 'setindex(' + pre[i].o + ',' + pre[i].k + ',' + v + ');';
      else out += nameSet(t.name, v);
    });
    return out + '}';
  }

  function assignTo(t, valueCode) {
    if (t.k === 'Name') return nameSet(t.name, valueCode);
    return 'setindex(' + gx(t.obj) + ',' + gx(t.key) + ',' + valueCode + ');';
  }

  function genNumFor(s) {
    const id = ++uid;
    const a = gx(s.a), b = gx(s.b);
    const c = s.c ? gx(s.c) : null;
    let stepConst = 1;
    if (s.c) {
      if (s.c.k === 'Num') stepConst = s.c.v;
      else stepConst = null;
    }
    const lb = 'Lp' + id;
    pushScope();
    const v = declare(s.name);
    fn.loops.push(lb);
    const body = genBlock(s.body);
    fn.loops.pop();
    popScope();
    let head = '{const $a' + id + '=fornum(' + a + ',"initial"),$b' + id + '=fornum(' + b + ',"limit")';
    let cond, stepCode;
    if (stepConst === null) {
      head += ',$c' + id + '=fornum(' + c + ',"step");if($c' + id + '===0)R.err("\'for\' step is zero");';
      cond = '($c' + id + '>0?$i' + id + '<=$b' + id + ':$i' + id + '>=$b' + id + ')';
      stepCode = '$i' + id + '+=$c' + id;
    } else {
      if (stepConst === 0) fail("'for' step is zero", s.line);
      head += ';';
      cond = stepConst > 0 ? '$i' + id + '<=$b' + id : '$i' + id + '>=$b' + id;
      stepCode = '$i' + id + '+=' + (stepConst < 0 ? '(' + stepConst + ')' : stepConst);
    }
    return head + lb + ':for(let $i' + id + '=$a' + id + ';' + cond + ';' + stepCode + '){if(--R.fuel<0)R.poll();let ' + v + '=$i' + id + ';' + body + '}}';
  }

  function genGenFor(s) {
    const id = ++uid;
    const items = exprListItems(s.exprs);
    const lb = 'Lp' + id;
    pushScope();
    const vars = s.names.map(declare);
    fn.loops.push(lb);
    const body = genBlock(s.body);
    fn.loops.pop();
    popScope();
    let out = '{const $g' + id + '=[' + items + '];const $f' + id + '=$g' + id + '[0],$s' + id + '=$g' + id + '[1];let $c' + id + '=$g' + id + '[2];';
    out += lb + ':while(true){if(--R.fuel<0)R.poll();const $r' + id + '=call($f' + id + ',$s' + id + ',$c' + id + ');';
    out += 'let ' + vars[0] + '=$r' + id + '[0];if(' + vars[0] + '===undefined)break ' + lb + ';$c' + id + '=' + vars[0] + ';';
    for (let i = 1; i < vars.length; i++) out += 'let ' + vars[i] + '=$r' + id + '[' + i + '];';
    out += body + '}}';
    return out;
  }

  // ---------- チャンク ----------
  pushScope();
  fn = { temps: [], vararg: true, loops: [], blocks: [] };
  const body = genBlock(ast.body);
  const temps = fn.temps.length ? 'let ' + fn.temps.join(',') + ';' : '';
  popScope();
  return 'function(...$va){' + temps + body + 'return E;}';
}

// ============================================================
// ランタイム: 値の表現 / テーブル / 演算 / メタテーブル / エラー
// ============================================================
const EMPTY = Object.freeze([]);
const E = EMPTY;

class LuaError extends Error {
  constructor(value) {
    super(typeof value === 'string' ? value : 'lua error');
    this.value = value;
  }
}
class LuaAbort extends Error {
  constructor() { super('aborted'); }
}

class LuaUserdata {
  constructor(kind, id) { this.kind = kind; this.id = id; this.meta = undefined; }
}

class LuaTable {
  constructor() {
    this.arr = [];             // キー 1..arr.length
    this.hash = new Map();     // それ以外のキー (0・負数・小数・文字列 など)
    this.meta = undefined;
  }
  get(k) {
    if (typeof k === 'number') {
      const a = this.arr;
      if (k >= 1 && k <= a.length && Number.isInteger(k)) return a[k - 1];
    }
    return this.hash.get(k);
  }
  set(k, v) {
    if (typeof k === 'number' && Number.isInteger(k) && k >= 1) {
      const a = this.arr, n = a.length;
      if (k <= n) {
        if (v === undefined && k === n) {
          a.pop();
          while (a.length > 0 && a[a.length - 1] === undefined) a.pop();
        } else {
          a[k - 1] = v;
        }
        return;
      }
      if (k === n + 1) {
        if (v === undefined) { this.hash.delete(k); return; }
        a.push(v);
        const h = this.hash;
        if (h.size > 0) {
          h.delete(k);
          while (h.has(a.length + 1)) {
            const nk = a.length + 1;
            a.push(h.get(nk));
            h.delete(nk);
          }
        }
        return;
      }
    }
    if (v === undefined) this.hash.delete(k);
    else this.hash.set(k, v);
  }
  length() { return this.arr.length; }
}

const R = {
  ln: 0,
  chunk: '?',
  fuel: 20000,
  native: null,       // セッションごとに差し込む
  G: null
};

function where() { return R.chunk + ':' + R.ln + ': '; }
function rtErr(msg) { return new LuaError(where() + msg); }
R.err = function (msg) { throw rtErr(msg); };

function typeName(v) {
  switch (typeof v) {
    case 'undefined': return 'nil';
    case 'boolean': return 'boolean';
    case 'number': return 'number';
    case 'string': return 'string';
    case 'function': return 'function';
    default:
      if (v === null) return 'nil';
      if (v instanceof LuaTable) return 'table';
      return 'userdata';
  }
}

function T(v) { return v !== undefined && v !== null && v !== false; }

// ---------- 数値 <-> 文字列 ----------
function fmtG(v, prec, alt) {
  if (v !== v) return 'nan';
  if (v === Infinity) return 'inf';
  if (v === -Infinity) return '-inf';
  if (prec === 0) prec = 1;
  if (v === 0) return (1 / v < 0 ? '-0' : '0');
  const ex = v.toExponential(prec - 1);                 // d.ddde+X
  const m = /^(-?)(\d)(?:\.(\d+))?e([+-]\d+)$/.exec(ex);
  const X = parseInt(m[4], 10);
  let out;
  if (X < -4 || X >= prec) {
    let mant = m[2] + (m[3] ? '.' + m[3] : '');
    if (!alt && mant.indexOf('.') >= 0) mant = mant.replace(/0+$/, '').replace(/\.$/, '');
    const ea = Math.abs(X);
    out = m[1] + mant + 'e' + (X < 0 ? '-' : '+') + (ea < 10 ? '0' + ea : String(ea));
  } else {
    let f = v.toFixed(Math.max(0, prec - 1 - X));
    if (!alt && f.indexOf('.') >= 0) f = f.replace(/0+$/, '').replace(/\.$/, '');
    out = f;
  }
  return out;
}

function numstr(v) {
  if (Number.isInteger(v) && Math.abs(v) < 1e15) return String(v === 0 ? 0 : v);
  return fmtG(v, 14, false);
}

function str2num(s) {
  s = s.trim();
  if (s === '') return undefined;
  if (/^[+-]?0[xX][0-9a-fA-F]+$/.test(s)) {
    const neg = s[0] === '-';
    const body = s.replace(/^[+-]?0[xX]/, '');
    const v = parseInt(body, 16);
    return neg ? -v : v;
  }
  if (/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(s)) return Number(s);
  return undefined;
}

let addrCounter = 0x1000;
const addrMap = new WeakMap();
function addrOf(o) {
  let a = addrMap.get(o);
  if (a === undefined) { addrCounter += 0x28; a = addrCounter; addrMap.set(o, a); }
  return '0x' + ('000000' + a.toString(16)).slice(-8);
}

function getMeta(v, name) {
  if (v instanceof LuaTable || v instanceof LuaUserdata) {
    const m = v.meta;
    if (m !== undefined) return m.get(name);
  }
  return undefined;
}

function tostr(v) {
  switch (typeof v) {
    case 'string': return v;
    case 'number': return numstr(v);
    case 'undefined': return 'nil';
    case 'boolean': return v ? 'true' : 'false';
    case 'function': return 'function: ' + addrOf(v);
  }
  if (v === null) return 'nil';
  const mm = getMeta(v, '__tostring');
  if (mm !== undefined) {
    const r = call(mm, v)[0];
    if (typeof r !== 'string') {
      if (typeof r === 'number') return numstr(r);
      throw rtErr("'__tostring' must return a string");
    }
    return r;
  }
  if (v instanceof LuaTable) return 'table: ' + addrOf(v);
  return 'userdata: ' + addrOf(v);
}

// ---------- 呼び出し / 添字 ----------
function call(f, ...args) {
  if (typeof f === 'function') return f(...args);
  const h = getMeta(f, '__call');
  if (h === undefined) throw rtErr('attempt to call a ' + typeName(f) + ' value');
  return call(h, f, ...args);
}

function callm(o, name, ...args) {
  const f = index(o, name);
  if (typeof f === 'function') return f(o, ...args);
  const h = getMeta(f, '__call');
  if (h === undefined) throw rtErr("attempt to call a " + typeName(f) + " value (method '" + name + "')");
  return call(h, f, o, ...args);
}

let stringLib = null;   // 後で差し込む

function index(o, k) {
  if (o instanceof LuaTable) {
    const v = o.get(k);
    if (v !== undefined || o.meta === undefined) return v;
    const h = o.meta.get('__index');
    if (h === undefined) return undefined;
    if (typeof h === 'function') return h(o, k)[0];
    return index(h, k);
  }
  if (typeof o === 'string') return stringLib.get(k);
  if (o instanceof LuaUserdata) {
    const h = getMeta(o, '__index');
    if (h === undefined) throw rtErr('attempt to index a userdata value');
    if (typeof h === 'function') return h(o, k)[0];
    return index(h, k);
  }
  throw rtErr('attempt to index a ' + typeName(o) + " value (field '" + (typeof k === 'string' ? k : '?') + "')");
}

function rawsetChecked(t, k, v) {
  if (k === undefined || k === null) throw rtErr('table index is nil');
  if (typeof k === 'number' && k !== k) throw rtErr('table index is NaN');
  t.set(k, v);
}

function setindex(o, k, v) {
  if (o instanceof LuaTable) {
    if (o.meta === undefined) { rawsetChecked(o, k, v); return; }
    if (o.get(k) !== undefined) { o.set(k, v); return; }
    const h = o.meta.get('__newindex');
    if (h === undefined) { rawsetChecked(o, k, v); return; }
    if (typeof h === 'function') { h(o, k, v); return; }
    setindex(h, k, v);
    return;
  }
  if (o instanceof LuaUserdata) {
    const h = getMeta(o, '__newindex');
    if (h === undefined) throw rtErr('attempt to index a userdata value');
    if (typeof h === 'function') { h(o, k, v); return; }
    setindex(h, k, v);
    return;
  }
  throw rtErr('attempt to index a ' + typeName(o) + ' value');
}

function mk(pos, kv) {
  const t = new LuaTable();
  if (pos !== undefined) {
    const a = t.arr;
    for (let i = 0; i < pos.length; i++) a.push(pos[i]);
    while (a.length > 0 && a[a.length - 1] === undefined) a.pop();
  }
  if (kv !== undefined) {
    for (let i = 0; i < kv.length; i += 2) {
      const k = kv[i];
      if (k === undefined || k === null) throw rtErr('table index is nil');
      t.set(k, kv[i + 1]);
    }
  }
  return t;
}

// ---------- 算術 ----------
function tonum(v) {
  if (typeof v === 'number') return v;
  if (typeof v === 'string') return str2num(v);
  return undefined;
}

function arithMeta(ev, a, b, opname) {
  let h = getMeta(a, ev);
  if (h === undefined) h = getMeta(b, ev);
  if (h !== undefined) return call(h, a, b)[0];
  const bad = (typeof a === 'number' || (typeof a === 'string' && str2num(a) !== undefined)) ? b : a;
  throw rtErr('attempt to perform arithmetic on a ' + typeName(bad) + ' value');
}

function arith2(ev, f, a, b) {
  const x = tonum(a), y = tonum(b);
  if (x !== undefined && y !== undefined) return f(x, y);
  return arithMeta(ev, a, b);
}

function add(a, b) { return (typeof a === 'number' && typeof b === 'number') ? a + b : arith2('__add', (x, y) => x + y, a, b); }
function sub(a, b) { return (typeof a === 'number' && typeof b === 'number') ? a - b : arith2('__sub', (x, y) => x - y, a, b); }
function mul(a, b) { return (typeof a === 'number' && typeof b === 'number') ? a * b : arith2('__mul', (x, y) => x * y, a, b); }
function div(a, b) { return (typeof a === 'number' && typeof b === 'number') ? a / b : arith2('__div', (x, y) => x / y, a, b); }
function fmod(x, y) {
  if (y === Infinity) return x >= 0 ? x : (x === -Infinity ? NaN : y);
  if (y === -Infinity) return x <= 0 ? x : y;
  const r = x % y;
  return (r !== 0 && (r < 0) !== (y < 0)) ? r + y : r;
}
function mod(a, b) { return (typeof a === 'number' && typeof b === 'number') ? fmod(a, b) : arith2('__mod', fmod, a, b); }
function pow(a, b) { return (typeof a === 'number' && typeof b === 'number') ? Math.pow(a, b) : arith2('__pow', Math.pow, a, b); }
function idiv(a, b) { return (typeof a === 'number' && typeof b === 'number') ? Math.floor(a / b) : arith2('__idiv', (x, y) => Math.floor(x / y), a, b); }
function unm(a) {
  if (typeof a === 'number') return -a;
  const x = tonum(a);
  if (x !== undefined) return -x;
  const h = getMeta(a, '__unm');
  if (h !== undefined) return call(h, a, a)[0];
  throw rtErr('attempt to perform arithmetic on a ' + typeName(a) + ' value');
}

// ビット演算 (32bit) -- 整数として扱う
function toint32(v, what) {
  const x = tonum(v);
  if (x === undefined) throw rtErr('attempt to perform bitwise operation on a ' + typeName(v) + ' value');
  if (!Number.isFinite(x)) throw rtErr('number has no integer representation');
  return Math.trunc(x);
}
function band(a, b) { return Number(BigInt.asIntN(64, BigInt(toint32(a)) & BigInt(toint32(b)))); }
function bor(a, b) { return Number(BigInt.asIntN(64, BigInt(toint32(a)) | BigInt(toint32(b)))); }
function bxor(a, b) { return Number(BigInt.asIntN(64, BigInt(toint32(a)) ^ BigInt(toint32(b)))); }
function shl(a, b) {
  const s = toint32(b);
  if (s < 0) return shr(a, -s);
  if (s >= 64) return 0;
  return Number(BigInt.asIntN(64, BigInt(toint32(a)) << BigInt(s)));
}
function shr(a, b) {
  const s = toint32(b);
  if (s < 0) return shl(a, -s);
  if (s >= 64) return 0;
  return Number(BigInt.asIntN(64, BigInt.asUintN(64, BigInt(toint32(a))) >> BigInt(s)));
}
function bnot(a) { return Number(BigInt.asIntN(64, ~BigInt(toint32(a)))); }

// ---------- 比較 / 連結 / 長さ ----------
function eq(a, b) {
  if (a === b) return true;
  if (a === null) a = undefined;
  if (b === null) b = undefined;
  if (a === b) return true;
  if (typeof a !== 'object' || typeof b !== 'object' || a === undefined || b === undefined) return false;
  if (!((a instanceof LuaTable && b instanceof LuaTable) || (a instanceof LuaUserdata && b instanceof LuaUserdata))) return false;
  let h = getMeta(a, '__eq');
  if (h === undefined) h = getMeta(b, '__eq');
  if (h === undefined) return false;
  return T(call(h, a, b)[0]);
}

function cmpErr(a, b) {
  const ta = typeName(a), tb = typeName(b);
  if (ta === tb) return rtErr('attempt to compare two ' + ta + ' values');
  return rtErr('attempt to compare ' + ta + ' with ' + tb);
}
function lt(a, b) {
  const ta = typeof a, tb = typeof b;
  if (ta === 'number' && tb === 'number') return a < b;
  if (ta === 'string' && tb === 'string') return a < b;
  let h = getMeta(a, '__lt');
  if (h === undefined) h = getMeta(b, '__lt');
  if (h === undefined) throw cmpErr(a, b);
  return T(call(h, a, b)[0]);
}
function le(a, b) {
  const ta = typeof a, tb = typeof b;
  if (ta === 'number' && tb === 'number') return a <= b;
  if (ta === 'string' && tb === 'string') return a <= b;
  let h = getMeta(a, '__le');
  if (h === undefined) h = getMeta(b, '__le');
  if (h !== undefined) return T(call(h, a, b)[0]);
  h = getMeta(a, '__lt');
  if (h === undefined) h = getMeta(b, '__lt');
  if (h === undefined) throw cmpErr(a, b);
  return !T(call(h, b, a)[0]);
}
function gt(a, b) { return lt(b, a); }
function ge(a, b) { return le(b, a); }

function concat(a, b) {
  const ta = typeof a, tb = typeof b;
  if ((ta === 'string' || ta === 'number') && (tb === 'string' || tb === 'number')) {
    return (ta === 'string' ? a : numstr(a)) + (tb === 'string' ? b : numstr(b));
  }
  let h = getMeta(a, '__concat');
  if (h === undefined) h = getMeta(b, '__concat');
  if (h !== undefined) return call(h, a, b)[0];
  const bad = (ta === 'string' || ta === 'number') ? b : a;
  throw rtErr('attempt to concatenate a ' + typeName(bad) + ' value');
}

function len(v) {
  if (typeof v === 'string') return v.length;
  if (v instanceof LuaTable) {
    const h = getMeta(v, '__len');
    if (h !== undefined) return call(h, v)[0];
    return v.arr.length;
  }
  const h = getMeta(v, '__len');
  if (h !== undefined) return call(h, v)[0];
  throw rtErr('attempt to get length of a ' + typeName(v) + ' value');
}

function fornum(v, what) {
  if (typeof v === 'number') return v;
  const x = typeof v === 'string' ? str2num(v) : undefined;
  if (x === undefined) throw rtErr("'for' " + what + ' value must be a number');
  return x;
}

R.poll = function () {
  R.fuel = 20000;
  if (R.native && R.native('poll') === true) throw new LuaAbort();
};

Object.assign(R, { call, callm, index, setindex, mk, T, eq, lt, le, gt, ge, add, sub, mul, div, mod, pow, idiv,
  unm, len, concat, band, bor, bxor, shl, shr, bnot, fornum });

// ---------- コンパイル ----------
const HELPERS = 'call,callm,index,setindex,mk,T,eq,lt,le,gt,ge,add,sub,mul,div,mod,pow,idiv,unm,len,concat,band,bor,bxor,shl,shr,bnot,fornum';

function compileLua(src, chunk, G) {
  const ast = parseLua(src, chunk);
  const js = generateJS(ast, chunk);
  R.lastJS = js;
  const factory = new Function('R', 'G', 'E', '"use strict";const {' + HELPERS + '}=R;return ' + js + ';');
  return factory(R, G, EMPTY);
}

// ============================================================
// 標準ライブラリ (base / string / table / math / os / io / bit32)
// ============================================================
function wrapFn(fn) {
  return function (...a) {
    const r = fn(...a);
    return r === undefined ? EMPTY : (Array.isArray(r) ? r : [r]);
  };
}
function lib(t, defs) {
  for (const k of Object.keys(defs)) t.set(k, wrapFn(defs[k]));
  return t;
}

function argErr(n, fname, msg) { return rtErr('bad argument #' + n + " to '" + fname + "' (" + msg + ')'); }
function typeOrNoValue(v) { return v === undefined ? 'no value' : typeName(v); }
function checkStr(v, n, fname) {
  if (typeof v === 'string') return v;
  if (typeof v === 'number') return numstr(v);
  throw argErr(n, fname, 'string expected, got ' + typeOrNoValue(v));
}
function checkNum(v, n, fname) {
  if (typeof v === 'number') return v;
  if (typeof v === 'string') { const x = str2num(v); if (x !== undefined) return x; }
  throw argErr(n, fname, 'number expected, got ' + typeOrNoValue(v));
}
function optNum(v, def, n, fname) { return v === undefined ? def : checkNum(v, n, fname); }
function checkInt(v, n, fname) {
  const x = checkNum(v, n, fname);
  return x !== x ? 0 : Math.trunc(x);
}
function optInt(v, def, n, fname) { return v === undefined ? def : checkInt(v, n, fname); }
function checkTable(v, n, fname) {
  if (v instanceof LuaTable) return v;
  throw argErr(n, fname, 'table expected, got ' + typeOrNoValue(v));
}

// ---------- Lua パターン (lstrlib.c の移植) ----------
const CAP_UNFINISHED = -1, CAP_POSITION = -2;
const isalpha = (c) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
const isdigit = (c) => c >= 48 && c <= 57;
const islower = (c) => c >= 97 && c <= 122;
const isupper = (c) => c >= 65 && c <= 90;
const isspace = (c) => c === 32 || (c >= 9 && c <= 13);
const iscntrl = (c) => c < 32 || c === 127;
const ispunct = (c) => (c >= 33 && c <= 47) || (c >= 58 && c <= 64) || (c >= 91 && c <= 96) || (c >= 123 && c <= 126);
const isalnum = (c) => isalpha(c) || isdigit(c);
const isxdigit = (c) => isdigit(c) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70);
const isgraph = (c) => c > 32 && c < 127;

function matchClass(c, cl) {
  let res;
  switch (cl | 32) {
    case 97: res = isalpha(c); break;
    case 99: res = iscntrl(c); break;
    case 100: res = isdigit(c); break;
    case 103: res = isgraph(c); break;
    case 108: res = islower(c); break;
    case 112: res = ispunct(c); break;
    case 115: res = isspace(c); break;
    case 117: res = isupper(c); break;
    case 119: res = isalnum(c); break;
    case 120: res = isxdigit(c); break;
    default: return cl === c;
  }
  if (isupper(cl)) res = !res;
  return res;
}

class MatchState {
  constructor(src, pat) { this.src = src; this.pat = pat; this.level = 0; this.capture = []; this.matchdepth = 0; }
}

function classEnd(ms, p) {
  const pat = ms.pat;
  const c = pat[p++];
  if (c === '%') {
    if (p >= pat.length) throw rtErr("malformed pattern (ends with '%')");
    return p + 1;
  }
  if (c === '[') {
    if (pat[p] === '^') p++;
    do {
      if (p >= pat.length) throw rtErr("malformed pattern (missing ']')");
      const cc = pat[p++];
      if (cc === '%' && p < pat.length) p++;
    } while (pat[p] !== ']');
    return p + 1;
  }
  return p;
}

function matchBracketClass(ms, c, p, ec) {
  const pat = ms.pat;
  let sig = true;
  if (pat[p + 1] === '^') { sig = false; p++; }
  while (++p < ec) {
    if (pat[p] === '%') {
      p++;
      if (matchClass(c, pat.charCodeAt(p))) return sig;
    } else if (pat[p + 1] === '-' && p + 2 < ec) {
      p += 2;
      if (pat.charCodeAt(p - 2) <= c && c <= pat.charCodeAt(p)) return sig;
    } else if (pat.charCodeAt(p) === c) return sig;
  }
  return !sig;
}

function singleMatch(ms, s, p, ep) {
  if (s >= ms.src.length) return false;
  const c = ms.src.charCodeAt(s);
  switch (ms.pat[p]) {
    case '.': return true;
    case '%': return matchClass(c, ms.pat.charCodeAt(p + 1));
    case '[': return matchBracketClass(ms, c, p, ep - 1);
    default: return ms.pat.charCodeAt(p) === c;
  }
}

function matchBalance(ms, s, p) {
  if (p + 1 >= ms.pat.length) throw rtErr("malformed pattern (missing arguments to '%b')");
  if (s >= ms.src.length || ms.src[s] !== ms.pat[p]) return -1;
  const b = ms.pat[p], e = ms.pat[p + 1];
  let cont = 1;
  for (let i = s + 1; i < ms.src.length; i++) {
    const c = ms.src[i];
    if (c === e) { if (--cont === 0) return i + 1; }
    else if (c === b) cont++;
  }
  return -1;
}

function maxExpand(ms, s, p, ep) {
  let i = 0;
  while (singleMatch(ms, s + i, p, ep)) i++;
  while (i >= 0) {
    const res = doMatch(ms, s + i, ep + 1);
    if (res !== -1) return res;
    i--;
  }
  return -1;
}

function minExpand(ms, s, p, ep) {
  for (;;) {
    const res = doMatch(ms, s, ep + 1);
    if (res !== -1) return res;
    if (singleMatch(ms, s, p, ep)) s++;
    else return -1;
  }
}

function startCapture(ms, s, p, what) {
  const level = ms.level;
  if (level >= 32) throw rtErr('too many captures');
  ms.capture[level] = { init: s, len: what };
  ms.level = level + 1;
  const res = doMatch(ms, s, p);
  if (res === -1) ms.level--;
  return res;
}

function captureToClose(ms) {
  for (let level = ms.level - 1; level >= 0; level--) {
    if (ms.capture[level].len === CAP_UNFINISHED) return level;
  }
  throw rtErr('invalid pattern capture');
}

function endCapture(ms, s, p) {
  const l = captureToClose(ms);
  ms.capture[l].len = s - ms.capture[l].init;
  const res = doMatch(ms, s, p);
  if (res === -1) ms.capture[l].len = CAP_UNFINISHED;
  return res;
}

function matchCapture(ms, s, lc) {
  const l = lc - 49;
  if (l < 0 || l >= ms.level || ms.capture[l].len === CAP_UNFINISHED) throw rtErr('invalid capture index %' + (l + 1));
  const len = ms.capture[l].len;
  const cap = ms.src.substr(ms.capture[l].init, len);
  if (ms.src.length - s >= len && ms.src.substr(s, len) === cap) return s + len;
  return -1;
}

function doMatch(ms, s, p) {
  if (++ms.matchdepth > 200) throw rtErr('pattern too complex');
  const r = doMatch0(ms, s, p);
  ms.matchdepth--;
  return r;
}

function doMatch0(ms, s, p) {
  const pat = ms.pat, plen = pat.length;
  for (;;) {
    if (p >= plen) return s;
    const pc = pat[p];
    if (pc === '(') {
      if (pat[p + 1] === ')') return startCapture(ms, s, p + 2, CAP_POSITION);
      return startCapture(ms, s, p + 1, CAP_UNFINISHED);
    }
    if (pc === ')') return endCapture(ms, s, p + 1);
    if (pc === '$' && p + 1 === plen) return s === ms.src.length ? s : -1;
    if (pc === '%') {
      const nc = pat[p + 1];
      if (nc === 'b') {
        s = matchBalance(ms, s, p + 2);
        if (s !== -1) { p += 4; continue; }
        return -1;
      }
      if (nc === 'f') {
        p += 2;
        if (pat[p] !== '[') throw rtErr("missing '[' after '%f' in pattern");
        const ep = classEnd(ms, p);
        const prev = s === 0 ? 0 : ms.src.charCodeAt(s - 1);
        const curc = s < ms.src.length ? ms.src.charCodeAt(s) : 0;
        if (!matchBracketClass(ms, prev, p, ep - 1) && matchBracketClass(ms, curc, p, ep - 1)) { p = ep; continue; }
        return -1;
      }
      if (nc !== undefined && nc >= '0' && nc <= '9') {
        s = matchCapture(ms, s, pat.charCodeAt(p + 1));
        if (s !== -1) { p += 2; continue; }
        return -1;
      }
    }
    const ep = classEnd(ms, p);
    const epc = pat[ep];
    if (!singleMatch(ms, s, p, ep)) {
      if (epc === '*' || epc === '?' || epc === '-') { p = ep + 1; continue; }
      return -1;
    }
    switch (epc) {
      case '?': {
        const res = doMatch(ms, s + 1, ep + 1);
        if (res !== -1) return res;
        p = ep + 1;
        continue;
      }
      case '+': return maxExpand(ms, s + 1, p, ep);
      case '*': return maxExpand(ms, s, p, ep);
      case '-': return minExpand(ms, s, p, ep);
      default: s++; p = ep; continue;
    }
  }
}

function getOneCapture(ms, i, s, e) {
  if (i >= ms.level) {
    if (i === 0) return ms.src.substring(s, e);
    throw rtErr('invalid capture index');
  }
  const l = ms.capture[i].len;
  if (l === CAP_UNFINISHED) throw rtErr('unfinished capture');
  if (l === CAP_POSITION) return ms.capture[i].init + 1;
  return ms.src.substr(ms.capture[i].init, l);
}

function pushCaptures(ms, s, e, wholeIfNone) {
  const n = (ms.level === 0 && wholeIfNone) ? 1 : ms.level;
  const out = [];
  for (let i = 0; i < n; i++) out.push(getOneCapture(ms, i, s, e));
  return out;
}

function posrelat(pos, len) {
  if (pos >= 0) return pos;
  if (-pos > len) return 0;
  return len + pos + 1;
}

const NO_SPECIALS = /[\^$*+?.()[\]%-]/;

function strFindAux(sv, pv, initv, plain, find, fname) {
  const s = checkStr(sv, 1, fname), pat = checkStr(pv, 2, fname);
  const ls = s.length;
  let init = initv === undefined ? 1 : posrelat(checkInt(initv, 3, fname), ls);
  if (init < 1) init = 1;
  if (init > ls + 1) return [undefined];
  const start = init - 1;
  if (find && (T(plain) || !NO_SPECIALS.test(pat))) {
    const idx = s.indexOf(pat, start);
    if (idx < 0) return [undefined];
    return [idx + 1, idx + pat.length];
  }
  const anchor = pat[0] === '^';
  const ms = new MatchState(s, pat);
  let s1 = start;
  do {
    ms.level = 0;
    ms.matchdepth = 0;
    const e = doMatch(ms, s1, anchor ? 1 : 0);
    if (e !== -1) {
      if (find) return [s1 + 1, e].concat(pushCaptures(ms, -1, -1, false));
      return pushCaptures(ms, s1, e, true);
    }
    s1++;
  } while (s1 <= ls && !anchor);
  return [undefined];
}

function gmatchFn(sv, pv) {
  const s = checkStr(sv, 1, 'gmatch'), pat = checkStr(pv, 2, 'gmatch');
  const ms = new MatchState(s, pat);
  let pos = 0, lastmatch = -1;
  return [function () {
    for (let src = pos; src <= s.length; src++) {
      ms.level = 0;
      ms.matchdepth = 0;
      const e = doMatch(ms, src, 0);
      if (e !== -1 && e !== lastmatch) {
        pos = lastmatch = e;
        return pushCaptures(ms, src, e, true);
      }
    }
    return [undefined];
  }];
}

function gsubFn(sv, pv, repl, maxv) {
  const s = checkStr(sv, 1, 'gsub'), pat = checkStr(pv, 2, 'gsub');
  const tr = typeName(repl);
  if (!(tr === 'string' || tr === 'number' || tr === 'table' || tr === 'function')) {
    throw argErr(3, 'gsub', 'string/function/table expected, got ' + typeOrNoValue(repl));
  }
  const srcl = s.length;
  const maxS = maxv === undefined ? srcl + 1 : checkInt(maxv, 4, 'gsub');
  const anchor = pat[0] === '^';
  const ms = new MatchState(s, pat);
  const replStr = (tr === 'string' || tr === 'number') ? tostr(repl) : null;
  let n = 0, src = 0, out = '';
  while (n < maxS) {
    ms.level = 0;
    ms.matchdepth = 0;
    const e = doMatch(ms, src, anchor ? 1 : 0);
    if (e !== -1) {
      n++;
      let val;
      if (replStr !== null) {
        val = '';
        for (let i = 0; i < replStr.length; i++) {
          const ch = replStr[i];
          if (ch !== '%') { val += ch; continue; }
          i++;
          const d = replStr[i];
          if (d === '%') val += '%';
          else if (d !== undefined && d >= '0' && d <= '9') {
            if (d === '0') val += s.substring(src, e);
            else val += tostr(getOneCapture(ms, d.charCodeAt(0) - 49, src, e));
          } else throw rtErr("invalid use of '%' in replacement string");
        }
      } else {
        let v;
        if (tr === 'table') v = index(repl, getOneCapture(ms, 0, src, e));
        else v = call(repl, ...pushCaptures(ms, src, e, true))[0];
        if (!T(v)) val = s.substring(src, e);
        else if (typeof v === 'string' || typeof v === 'number') val = tostr(v);
        else throw rtErr('invalid replacement value (a ' + typeName(v) + ')');
      }
      out += val;
    }
    if (e !== -1 && e > src) src = e;
    else if (src < srcl) out += s[src++];
    else break;
    if (anchor) break;
  }
  out += s.substring(src);
  return [out, n];
}

// ---------- string.format ----------
function padNum(sign, digits, width, left, zeroPad) {
  const l = sign.length + digits.length;
  if (l >= width) return sign + digits;
  if (left) return sign + digits + ' '.repeat(width - l);
  if (zeroPad) return sign + '0'.repeat(width - l) + digits;
  return ' '.repeat(width - l) + sign + digits;
}
function padStr(s, width, left) {
  if (s.length >= width) return s;
  return left ? s + ' '.repeat(width - s.length) : ' '.repeat(width - s.length) + s;
}
function fixExp(s) { return s.replace(/e([+-])(\d)$/, 'e$10$2'); }

function sformat(fmtv, ...args) {
  const fmt = checkStr(fmtv, 1, 'format');
  const n = fmt.length;
  let out = '', ai = 0;
  for (let i = 0; i < n; i++) {
    const c = fmt[i];
    if (c !== '%') { out += c; continue; }
    i++;
    if (i >= n) throw rtErr("invalid option '%' to 'format'");
    if (fmt[i] === '%') { out += '%'; continue; }
    let left = false, plus = false, space = false, alt = false, zero = false;
    for (; i < n; i++) {
      const f = fmt[i];
      if (f === '-') left = true;
      else if (f === '+') plus = true;
      else if (f === ' ') space = true;
      else if (f === '#') alt = true;
      else if (f === '0') zero = true;
      else break;
    }
    let width = 0;
    while (i < n && fmt[i] >= '0' && fmt[i] <= '9') { width = width * 10 + (fmt.charCodeAt(i) - 48); i++; }
    let prec = -1;
    if (fmt[i] === '.') {
      i++;
      prec = 0;
      while (i < n && fmt[i] >= '0' && fmt[i] <= '9') { prec = prec * 10 + (fmt.charCodeAt(i) - 48); i++; }
    }
    const conv = fmt[i];
    if (conv === undefined) throw rtErr("invalid option '%' to 'format'");
    const argn = ai + 2;
    const arg = args[ai++];
    if (ai > args.length) throw argErr(argn, 'format', 'no value');
    switch (conv) {
      case 'd': case 'i': case 'u': {
        const v = Math.trunc(checkNum(arg, argn, 'format'));
        let digits = String(Math.abs(v));
        if (prec >= 0) digits = digits.padStart(prec, '0');
        const sign = v < 0 ? '-' : (plus ? '+' : (space ? ' ' : ''));
        out += padNum(sign, digits, width, left, zero && prec < 0);
        break;
      }
      case 'c':
        out += padStr(String.fromCharCode(checkInt(arg, argn, 'format')), width, left);
        break;
      case 'x': case 'X': case 'o': {
        let v = Math.trunc(checkNum(arg, argn, 'format'));
        const radix = conv === 'o' ? 8 : 16;
        let digits = v < 0 ? BigInt.asUintN(64, BigInt(v)).toString(radix) : v.toString(radix);
        if (prec >= 0) digits = digits.padStart(prec, '0');
        if (alt && v !== 0) digits = (conv === 'o' ? '0' : '0x') + digits;
        if (conv === 'X') digits = digits.toUpperCase();
        out += padNum('', digits, width, left, zero && prec < 0);
        break;
      }
      case 'e': case 'E': case 'f': case 'F': case 'g': case 'G': {
        const v = checkNum(arg, argn, 'format');
        const sign = (v < 0 || Object.is(v, -0)) ? '-' : (plus ? '+' : (space ? ' ' : ''));
        const av = Math.abs(v);
        let digits;
        const finite = Number.isFinite(av);
        if (!finite) digits = av !== av ? 'nan' : 'inf';
        else if (conv === 'f' || conv === 'F') digits = av.toFixed(prec < 0 ? 6 : Math.min(prec, 100));
        else if (conv === 'e' || conv === 'E') digits = fixExp(av.toExponential(prec < 0 ? 6 : Math.min(prec, 100)));
        else digits = fmtG(av, prec < 0 ? 6 : prec, alt);
        if (conv === 'E' || conv === 'F' || conv === 'G') digits = digits.toUpperCase();
        out += padNum(sign, digits, width, left, zero && finite);
        break;
      }
      case 's': {
        let s = tostr(arg);
        if (prec >= 0) s = s.substring(0, prec);
        out += padStr(s, width, left);
        break;
      }
      case 'q': {
        const s = checkStr(arg, argn, 'format');
        out += '"' + s.replace(/[\\"\n\r\0]/g, (m) => m === '\n' ? '\\n' : m === '\r' ? '\\r' : m === '\0' ? '\\0' : '\\' + m) + '"';
        break;
      }
      default:
        throw rtErr("invalid option '%" + conv + "' to 'format'");
    }
  }
  return out;
}

// ---------- ライブラリ本体を作る ----------
function makeStringLib() {
  const S = new LuaTable();
  lib(S, {
    len: (s) => checkStr(s, 1, 'len').length,
    sub: (sv, iv, jv) => {
      const s = checkStr(sv, 1, 'sub');
      const l = s.length;
      let i = posrelat(optInt(iv, 1, 2, 'sub'), l);
      let j = posrelat(optInt(jv, -1, 3, 'sub'), l);
      if (i < 1) i = 1;
      if (j > l) j = l;
      return i > j ? '' : s.substring(i - 1, j);
    },
    upper: (s) => checkStr(s, 1, 'upper').toUpperCase(),
    lower: (s) => checkStr(s, 1, 'lower').toLowerCase(),
    reverse: (s) => checkStr(s, 1, 'reverse').split('').reverse().join(''),
    rep: (sv, nv, sepv) => {
      const s = checkStr(sv, 1, 'rep');
      const n = checkInt(nv, 2, 'rep');
      if (n <= 0) return '';
      const sep = sepv === undefined ? '' : checkStr(sepv, 3, 'rep');
      if ((s.length + sep.length) * n > 64 * 1024 * 1024) throw rtErr('resulting string too large');
      if (sep === '') return s.repeat(n);
      return (s + sep).repeat(n - 1) + s;
    },
    byte: (sv, iv, jv) => {
      const s = checkStr(sv, 1, 'byte');
      const l = s.length;
      let i = posrelat(optInt(iv, 1, 2, 'byte'), l);
      let j = jv === undefined ? i : posrelat(checkInt(jv, 3, 'byte'), l);
      if (i < 1) i = 1;
      if (j > l) j = l;
      const out = [];
      for (let k = i; k <= j; k++) out.push(s.charCodeAt(k - 1));
      return out;
    },
    char: (...a) => a.map((v, i) => String.fromCharCode(checkInt(v, i + 1, 'char'))).join(''),
    format: sformat,
    find: (s, p, init, plain) => strFindAux(s, p, init, plain, true, 'find'),
    match: (s, p, init) => strFindAux(s, p, init, false, false, 'match'),
    gmatch: gmatchFn,
    gsub: gsubFn
  });
  return S;
}

function tableInsert(t, ...a) {
  checkTable(t, 1, 'insert');
  if (a.length === 1) {
    t.set(t.arr.length + 1, a[0]);
    return;
  }
  if (a.length !== 2) throw rtErr("wrong number of arguments to 'insert'");
  const n = t.arr.length;
  const pos = checkInt(a[0], 2, 'insert');
  if (pos < 1 || pos > n + 1) throw argErr(2, 'insert', 'position out of bounds');
  if (pos === n + 1) { t.set(pos, a[1]); return; }
  t.arr.splice(pos - 1, 0, a[1]);
  t.migrate();
}

function tableRemove(t, p) {
  checkTable(t, 1, 'remove');
  const n = t.arr.length;
  if (p === undefined) {
    if (n === 0) return [undefined];
    const v = t.arr[n - 1];
    t.set(n, undefined);
    return [v];
  }
  const pos = checkInt(p, 2, 'remove');
  if (n === 0 && (pos === 0 || pos === n)) return [t.get(pos)];
  if (n + 1 === pos) { const v = t.get(pos); t.set(pos, undefined); return [v]; }
  if (pos < 1 || pos > n + 1) throw argErr(2, 'remove', 'position out of bounds');
  const v = t.arr.splice(pos - 1, 1)[0];
  while (t.arr.length > 0 && t.arr[t.arr.length - 1] === undefined) t.arr.pop();
  return [v];
}

LuaTable.prototype.migrate = function () {
  const a = this.arr, h = this.hash;
  while (h.size > 0 && h.has(a.length + 1)) {
    const nk = a.length + 1;
    a.push(h.get(nk));
    h.delete(nk);
  }
};

function tableConcat(t, sepv, iv, jv) {
  checkTable(t, 1, 'concat');
  const sep = sepv === undefined ? '' : checkStr(sepv, 2, 'concat');
  const i = optInt(iv, 1, 3, 'concat');
  const j = jv === undefined ? t.arr.length : checkInt(jv, 4, 'concat');
  const parts = [];
  for (let k = i; k <= j; k++) {
    const v = t.get(k);
    if (typeof v === 'string') parts.push(v);
    else if (typeof v === 'number') parts.push(numstr(v));
    else throw rtErr("invalid value (at index " + k + ") in table for 'concat'");
  }
  return parts.join(sep);
}

function tableSort(t, cmp) {
  checkTable(t, 1, 'sort');
  if (cmp !== undefined && typeof cmp !== 'function' && getMeta(cmp, '__call') === undefined) {
    throw argErr(2, 'sort', 'function expected, got ' + typeName(cmp));
  }
  const a = t.arr;
  const n = a.length;
  const list = a.slice();
  const less = cmp === undefined ? lt : (x, y) => T(call(cmp, x, y)[0]);
  list.sort((x, y) => (less(x, y) ? -1 : (less(y, x) ? 1 : 0)));
  for (let i = 0; i < n; i++) a[i] = list[i];
}

function tableUnpack(t, iv, jv) {
  const i = optInt(iv, 1, 2, 'unpack');
  const j = jv === undefined ? len(t) : checkInt(jv, 3, 'unpack');
  if (j - i >= 1000000) throw rtErr('too many results to unpack');
  const out = [];
  for (let k = i; k <= j; k++) out.push(index(t, k));
  return out;
}

function makeTableLib() {
  const Tt = new LuaTable();
  lib(Tt, {
    insert: tableInsert,
    remove: tableRemove,
    concat: tableConcat,
    sort: tableSort,
    unpack: tableUnpack,
    pack: (...a) => { const t = mk(a); t.set('n', a.length); return t; },
    maxn: (t) => {
      checkTable(t, 1, 'maxn');
      let m = t.arr.length;
      for (const k of t.hash.keys()) if (typeof k === 'number' && k > m) m = k;
      return m;
    },
    move: (a1, f, e, t, a2) => {
      const dst = a2 === undefined ? a1 : a2;
      const fi = checkInt(f, 2, 'move'), ei = checkInt(e, 3, 'move'), ti = checkInt(t, 4, 'move');
      if (ei >= fi) {
        if (ti > ei || ti <= fi || dst !== a1) for (let i = 0; i <= ei - fi; i++) setindex(dst, ti + i, index(a1, fi + i));
        else for (let i = ei - fi; i >= 0; i--) setindex(dst, ti + i, index(a1, fi + i));
      }
      return dst;
    }
  });
  return Tt;
}

function makeMathLib() {
  const M = new LuaTable();
  const n1 = (name, f) => (x) => f(checkNum(x, 1, name));
  lib(M, {
    floor: n1('floor', Math.floor), ceil: n1('ceil', Math.ceil), sqrt: n1('sqrt', Math.sqrt),
    abs: n1('abs', Math.abs), sin: n1('sin', Math.sin), cos: n1('cos', Math.cos), tan: n1('tan', Math.tan),
    asin: n1('asin', Math.asin), acos: n1('acos', Math.acos), exp: n1('exp', Math.exp),
    sinh: n1('sinh', Math.sinh), cosh: n1('cosh', Math.cosh), tanh: n1('tanh', Math.tanh),
    deg: n1('deg', (x) => x * 180 / Math.PI), rad: n1('rad', (x) => x * Math.PI / 180),
    atan: (y, x) => Math.atan2(checkNum(y, 1, 'atan'), optNum(x, 1, 2, 'atan')),
    atan2: (y, x) => Math.atan2(checkNum(y, 1, 'atan2'), checkNum(x, 2, 'atan2')),
    pow: (a, b) => Math.pow(checkNum(a, 1, 'pow'), checkNum(b, 2, 'pow')),
    fmod: (a, b) => checkNum(a, 1, 'fmod') % checkNum(b, 2, 'fmod'),
    log: (x, b) => {
      const v = checkNum(x, 1, 'log');
      if (b === undefined) return Math.log(v);
      const base = checkNum(b, 2, 'log');
      if (base === 10) return Math.log10(v);
      if (base === 2) return Math.log2(v);
      return Math.log(v) / Math.log(base);
    },
    log10: n1('log10', Math.log10),
    modf: (x) => {
      const v = checkNum(x, 1, 'modf');
      const ip = v >= 0 ? Math.floor(v) : Math.ceil(v);
      return [ip, Number.isFinite(v) ? v - ip : 0];
    },
    max: (...a) => {
      let m = checkNum(a[0], 1, 'max');
      for (let i = 1; i < a.length; i++) { const v = checkNum(a[i], i + 1, 'max'); if (v > m) m = v; }
      return m;
    },
    min: (...a) => {
      let m = checkNum(a[0], 1, 'min');
      for (let i = 1; i < a.length; i++) { const v = checkNum(a[i], i + 1, 'min'); if (v < m) m = v; }
      return m;
    },
    random: (a, b) => {
      if (a === undefined) return Math.random();
      let lo = 1, hi;
      if (b === undefined) hi = checkInt(a, 1, 'random');
      else { lo = checkInt(a, 1, 'random'); hi = checkInt(b, 2, 'random'); }
      if (lo > hi) throw argErr(b === undefined ? 1 : 2, 'random', 'interval is empty');
      return lo + Math.floor(Math.random() * (hi - lo + 1));
    },
    randomseed: () => undefined,
    tointeger: (x) => (typeof x === 'number' && Number.isInteger(x)) ? x : undefined,
    type: (x) => typeof x === 'number' ? (Number.isInteger(x) ? 'integer' : 'float') : undefined,
    ult: (a, b) => BigInt.asUintN(64, BigInt(Math.trunc(a))) < BigInt.asUintN(64, BigInt(Math.trunc(b)))
  });
  M.set('pi', Math.PI);
  M.set('huge', Infinity);
  M.set('maxinteger', 9007199254740991);
  M.set('mininteger', -9007199254740991);
  return M;
}

function pad2(n) { return n < 10 ? '0' + n : String(n); }
const DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

function osDate(fmtv, tv) {
  let fmt = fmtv === undefined ? '%c' : checkStr(fmtv, 1, 'date');
  const t = tv === undefined ? Date.now() : checkNum(tv, 2, 'date') * 1000;
  let utc = false;
  if (fmt[0] === '!') { utc = true; fmt = fmt.slice(1); }
  const d = new Date(t);
  const g = {
    Y: utc ? d.getUTCFullYear() : d.getFullYear(), m: (utc ? d.getUTCMonth() : d.getMonth()) + 1,
    d: utc ? d.getUTCDate() : d.getDate(), H: utc ? d.getUTCHours() : d.getHours(),
    M: utc ? d.getUTCMinutes() : d.getMinutes(), S: utc ? d.getUTCSeconds() : d.getSeconds(),
    w: utc ? d.getUTCDay() : d.getDay()
  };
  if (fmt.slice(0, 2) === '*t') {
    const r = new LuaTable();
    r.set('year', g.Y); r.set('month', g.m); r.set('day', g.d); r.set('hour', g.H);
    r.set('min', g.M); r.set('sec', g.S); r.set('wday', g.w + 1);
    const start = new Date(g.Y, 0, 1);
    r.set('yday', Math.floor((new Date(g.Y, g.m - 1, g.d) - start) / 86400000) + 1);
    r.set('isdst', false);
    return r;
  }
  return fmt.replace(/%(.)/g, (m, c) => {
    switch (c) {
      case 'Y': return String(g.Y);
      case 'y': return pad2(g.Y % 100);
      case 'm': return pad2(g.m);
      case 'd': return pad2(g.d);
      case 'H': return pad2(g.H);
      case 'I': return pad2(g.H % 12 === 0 ? 12 : g.H % 12);
      case 'M': return pad2(g.M);
      case 'S': return pad2(g.S);
      case 'p': return g.H < 12 ? 'AM' : 'PM';
      case 'A': return DAYS[g.w];
      case 'a': return DAYS[g.w].slice(0, 3);
      case 'B': return MONTHS[g.m - 1];
      case 'b': return MONTHS[g.m - 1].slice(0, 3);
      case 'c': return DAYS[g.w].slice(0, 3) + ' ' + MONTHS[g.m - 1].slice(0, 3) + ' ' + pad2(g.d) + ' ' + pad2(g.H) + ':' + pad2(g.M) + ':' + pad2(g.S) + ' ' + g.Y;
      case 'x': return pad2(g.m) + '/' + pad2(g.d) + '/' + pad2(g.Y % 100);
      case 'X': return pad2(g.H) + ':' + pad2(g.M) + ':' + pad2(g.S);
      case '%': return '%';
      default: return m;
    }
  });
}

const START_MS = Date.now();

function makeOsLib() {
  const O = new LuaTable();
  lib(O, {
    time: (t) => {
      if (t === undefined) return Math.floor(Date.now() / 1000);
      checkTable(t, 1, 'time');
      const f = (k, d) => { const v = t.get(k); return v === undefined ? d : checkNum(v, 1, 'time'); };
      return Math.floor(new Date(f('year', 1970), f('month', 1) - 1, f('day', 1), f('hour', 12), f('min', 0), f('sec', 0)).getTime() / 1000);
    },
    clock: () => (Date.now() - START_MS) / 1000,
    date: osDate,
    difftime: (a, b) => checkNum(a, 1, 'difftime') - optNum(b, 0, 2, 'difftime'),
    getenv: () => undefined,
    tmpname: () => 'lua_tmp',
    exit: () => { throw rtErr('os.exit is not supported'); },
    remove: () => [undefined, 'os.remove is not supported'],
    rename: () => [undefined, 'os.rename is not supported']
  });
  return O;
}

function makeBit32Lib() {
  const B = new LuaTable();
  const u = (v, n, name) => (checkInt(v, n, name) >>> 0);
  lib(B, {
    band: (...a) => a.reduce((acc, v, i) => (acc & u(v, i + 1, 'band')) >>> 0, 0xFFFFFFFF),
    bor: (...a) => a.reduce((acc, v, i) => (acc | u(v, i + 1, 'bor')) >>> 0, 0),
    bxor: (...a) => a.reduce((acc, v, i) => (acc ^ u(v, i + 1, 'bxor')) >>> 0, 0),
    bnot: (x) => (~u(x, 1, 'bnot')) >>> 0,
    btest: (...a) => a.reduce((acc, v, i) => (acc & u(v, i + 1, 'btest')) >>> 0, 0xFFFFFFFF) !== 0,
    lshift: (x, n) => { const s = checkInt(n, 2, 'lshift'); return s >= 32 ? 0 : (s < 0 ? (u(x, 1, 'lshift') >>> Math.min(-s, 31)) : (u(x, 1, 'lshift') << s) >>> 0); },
    rshift: (x, n) => { const s = checkInt(n, 2, 'rshift'); return s >= 32 ? 0 : (s < 0 ? (u(x, 1, 'rshift') << Math.min(-s, 31)) >>> 0 : u(x, 1, 'rshift') >>> s); },
    arshift: (x, n) => { const s = Math.min(checkInt(n, 2, 'arshift'), 31); return (checkInt(x, 1, 'arshift') >> s) >>> 0; }
  });
  return B;
}

function nextFn(t, k) {
  checkTable(t, 1, 'next');
  const keys = [];
  const a = t.arr;
  for (let i = 0; i < a.length; i++) if (a[i] !== undefined) keys.push(i + 1);
  for (const hk of t.hash.keys()) keys.push(hk);
  let pos = 0;
  if (k !== undefined) {
    const idx = keys.indexOf(k);
    if (idx < 0) throw rtErr("invalid key to 'next'");
    pos = idx + 1;
  }
  if (pos >= keys.length) return [undefined];
  const key = keys[pos];
  return [key, t.get(key)];
}

function pairsFn(t) {
  const mm = getMeta(t, '__pairs');
  if (mm !== undefined) {
    const r = call(mm, t);
    return [r[0], r[1], r[2]];
  }
  if (!(t instanceof LuaTable)) throw argErr(1, 'pairs', 'table expected, got ' + typeOrNoValue(t));
  let keys = null, i = 0, ai = 0;
  const iter = function () {
    const a = t.arr;
    while (ai < a.length) {
      const v = a[ai++];
      if (v !== undefined) return [ai, v];
    }
    if (keys === null) keys = Array.from(t.hash.keys());
    while (i < keys.length) {
      const k = keys[i++];
      const v = t.hash.get(k);
      if (v !== undefined) return [k, v];
    }
    return [undefined];
  };
  return [iter, t, undefined];
}

function ipairsFn(t) {
  if (t === undefined) throw argErr(1, 'ipairs', 'table expected, got no value');
  const iter = function (tt, i) {
    const n = i + 1;
    const v = index(tt, n);
    return v === undefined ? [undefined] : [n, v];
  };
  return [iter, t, 0];
}

function errorValue(e) {
  if (e instanceof LuaError) return e.value;
  if (e instanceof LuaSyntaxError) return e.message;
  if (e instanceof RangeError) return where() + 'stack overflow';
  return where() + String(e && e.message ? e.message : e);
}

function makeStringMeta() {
  const m = new LuaTable();
  m.set('__index', stringLib);
  return m;
}

// 1回の実行 (セッション) ごとにグローバル環境を作る
function makeGlobals(printFn) {
  const G = new LuaTable();
  const S = makeStringLib();
  stringLib = S;
  const stringMeta = makeStringMeta();
  G.set('_G', G);
  G.set('_VERSION', 'Lua 5.2');
  G.set('string', S);
  G.set('table', makeTableLib());
  G.set('math', makeMathLib());
  G.set('os', makeOsLib());
  G.set('bit32', makeBit32Lib());

  const io = new LuaTable();
  const writeOut = (...a) => { printFn(a.map((v, i) => checkStr(v, i + 1, 'write')).join(''), true); };
  lib(io, { write: writeOut, read: () => undefined });
  const stdout = new LuaTable();
  lib(stdout, { write: (self, ...a) => { writeOut(...a); return self; } });
  io.set('stdout', stdout);
  io.set('stderr', stdout);
  G.set('io', io);

  const co = new LuaTable();
  const noCo = () => { throw rtErr('coroutines are not supported in this plugin runtime'); };
  lib(co, { create: noCo, resume: noCo, yield: noCo, wrap: noCo, status: noCo, isyieldable: () => false, running: noCo });
  G.set('coroutine', co);

  lib(G, {
    print: (...a) => { printFn(a.map(tostr).join('\t'), false); },
    type: (...a) => {
      if (a.length === 0) throw argErr(1, 'type', 'value expected');
      return typeName(a[0]);
    },
    tostring: (v) => tostr(v),
    tonumber: (v, base) => {
      if (base === undefined) {
        if (typeof v === 'number') return v;
        if (typeof v === 'string') return [str2num(v)];
        return [undefined];
      }
      const b = checkInt(base, 2, 'tonumber');
      if (b < 2 || b > 36) throw argErr(2, 'tonumber', 'base out of range');
      const s = checkStr(v, 1, 'tonumber').trim().toLowerCase();
      if (!/^-?[0-9a-z]+$/.test(s)) return [undefined];
      let neg = false, body = s;
      if (s[0] === '-') { neg = true; body = s.slice(1); }
      let r = 0;
      for (const ch of body) {
        const d = parseInt(ch, 36);
        if (d >= b) return [undefined];
        r = r * b + d;
      }
      return neg ? -r : r;
    },
    pairs: pairsFn,
    ipairs: ipairsFn,
    next: nextFn,
    select: (n, ...a) => {
      if (n === '#') return a.length;
      let i = checkInt(n, 1, 'select');
      if (i < 0) i = a.length + i + 1;
      else if (i > a.length) return [];
      if (i < 1) throw argErr(1, 'select', 'index out of range');
      return a.slice(i - 1);
    },
    rawget: (t, k) => checkTable(t, 1, 'rawget').get(k),
    rawset: (t, k, v) => { rawsetChecked(checkTable(t, 1, 'rawset'), k, v); return t; },
    rawequal: (a, b) => a === b,
    rawlen: (v) => (v instanceof LuaTable ? v.arr.length : (typeof v === 'string' ? v.length : 0)),
    setmetatable: (t, m) => {
      checkTable(t, 1, 'setmetatable');
      if (m !== undefined && !(m instanceof LuaTable)) throw argErr(2, 'setmetatable', 'nil or table expected');
      if (t.meta !== undefined && t.meta.get('__metatable') !== undefined) throw rtErr('cannot change a protected metatable');
      t.meta = m;
      return t;
    },
    getmetatable: (v) => {
      if (typeof v === 'string') return stringMeta;
      if (v instanceof LuaTable || v instanceof LuaUserdata) {
        if (v.meta === undefined) return undefined;
        const p = v.meta.get('__metatable');
        return p !== undefined ? p : v.meta;
      }
      return undefined;
    },
    assert: (...a) => {
      if (!T(a[0])) {
        if (a.length < 2) throw new LuaError('assertion failed!');
        throw new LuaError(a[1]);
      }
      return a;
    },
    error: (msg, level) => {
      if (typeof msg === 'string' && level !== 0) msg = where() + msg;
      throw new LuaError(msg);
    },
    pcall: (f, ...args) => {
      if (f === undefined && args.length === 0) throw argErr(1, 'pcall', 'value expected');
      const ln = R.ln;
      try {
        return [true].concat(call(f, ...args));
      } catch (e) {
        if (e instanceof LuaAbort) throw e;
        R.ln = ln;
        return [false, errorValue(e)];
      }
    },
    xpcall: (f, h, ...args) => {
      const ln = R.ln;
      try {
        return [true].concat(call(f, ...args));
      } catch (e) {
        if (e instanceof LuaAbort) throw e;
        R.ln = ln;
        return [false].concat(call(h, errorValue(e)).slice(0, 1));
      }
    },
    unpack: tableUnpack,
    collectgarbage: (opt) => (opt === 'count' ? 0 : 0),
    load: (chunk, name) => {
      let src = chunk;
      if (typeof chunk === 'function') {
        src = '';
        for (;;) {
          const piece = call(chunk)[0];
          if (piece === undefined || piece === '') break;
          src += piece;
        }
      }
      try {
        return compileLua(checkStr(src, 1, 'load'), typeof name === 'string' ? name.replace(/^[=@]/, '') : '(load)', G);
      } catch (e) {
        return [undefined, errorValue(e)];
      }
    },
    dofile: () => { throw rtErr('dofile is not supported'); },
    require: (n) => { throw rtErr("module '" + tostr(n) + "' not found (require is not supported)"); }
  });
  G.set('loadstring', G.get('load'));
  return G;
}

// ============================================================
// Editor API (Malody V プラグイン向け) と Swift から呼ぶ入口 LuaHost
//   エディタ本体への操作は native(name, ...args) で Swift に橋渡しする
// ============================================================
function gcdN(a, b) {
  a = Math.abs(a); b = Math.abs(b);
  while (b) { const t = a % b; a = b; b = t; }
  return a;
}

// [beat, numor, denom] を「分子は 0..denom-1 / 約分済み」の形にそろえる
function beatNorm(m, n, d) {
  m = Math.trunc(Number(m) || 0);
  n = Math.trunc(Number(n) || 0);
  d = Math.trunc(Number(d) || 1);
  if (d < 1) d = 1;
  let t = m * d + n;
  const g = gcdN(t, d) || 1;
  t /= g;
  d /= g;
  const mm = Math.floor(t / d);
  return [mm, t - mm * d, d];
}

function beatTable(arr) {
  const t = new LuaTable();
  t.set('beat', arr[0]);
  t.set('numor', arr[1]);
  t.set('denom', arr[2]);
  return t;
}

function beatArr(v, argn, fname) {
  if (!(v instanceof LuaTable)) throw argErr(argn, fname, 'beat table expected, got ' + typeOrNoValue(v));
  const f = (k, dflt) => { const x = v.get(k); return typeof x === 'number' ? x : dflt; };
  return [f('beat', 0), f('numor', 0), f('denom', 1)];
}

function beatValue(a) { return a[0] + a[1] / a[2]; }

function beatCombine(a, b, sign) {
  const l = a[2] / gcdN(a[2], b[2]) * b[2];
  if (l <= 4194304) {
    const ta = (a[0] * a[2] + a[1]) * (l / a[2]);
    const tb = (b[0] * b[2] + b[1]) * (l / b[2]);
    return beatNorm(0, ta + sign * tb, l);
  }
  const v = beatValue(a) + sign * beatValue(b);
  return beatNorm(0, Math.round(v * 1048576), 1048576);
}

function native(name, ...args) {
  const r = root.__native(name, JSON.stringify(args));
  const v = JSON.parse(r);
  const x = v[0];
  return x === null ? undefined : x;
}
R.native = native;

function makeEditor() {
  const Ed = new LuaTable();
  const def = (name, fn) => {
    Ed.set(name, function (self, ...a) { return [fn(...a)]; });
  };
  // ノーツは 1, 2, 3… の番号で渡す (本物の Malody もノーツ ID は数値。'm-' .. note .. 'grip' のように、文字列と連結できる)
  const idToHandle = new Map();     // エディタ内部の ID (UUID 文字列) -> ノーツ番号
  const handleToId = new Map();
  let nextHandle = 1;
  const ref = (id) => {
    let h = idToHandle.get(id);
    if (h === undefined) { h = nextHandle++; idToHandle.set(id, h); handleToId.set(h, id); }
    return h;
  };
  const nid = (v, n, fname) => {
    const id = handleToId.get(v);
    if (id !== undefined) return id;
    throw argErr(n, fname, 'note expected, got ' + (v === undefined ? 'no value' : tostr(v)));
  };
  const headFlag = (f) => (f === undefined ? true : T(f));    // GetNoteBeat(note, true) = 始点 / (note, false) = 終点
  const noteList = (ids) => {
    const t = new LuaTable();
    t.set('Length', ids.length);
    for (let i = 0; i < ids.length; i++) t.set(i, ref(ids[i]));
    return t;
  };
  const num = (v, n, fname) => checkNum(v, n, fname);

  // ----- 情報の取得 -----
  def('GetCurrentTime', () => native('currentTimeMs'));
  def('GetSystemTime', () => Date.now());
  def('GetCurrentBeat', () => beatTable(native('currentBeat')));
  def('GetCurrentDivide', () => native('divide'));
  def('GetSelectNotes', () => noteList(native('selected')));
  // このエディタ独自: 「順番に選択」(Order ボタン) でタップした順のスライド / その順番のリセット
  def('GetOrderNotes', () => noteList(native('ordered')));
  def('ClearOrderNotes', () => { native('clearOrder'); });
  def('GetNoteCount', () => native('noteCount'));
  def('GetNoteAt', (i) => {
    const id = native('noteAt', checkInt(i, 1, 'GetNoteAt'));
    return id === undefined ? undefined : ref(id);
  });
  def('GetNoteTime', (n, head) => native('noteTime', nid(n, 1, 'GetNoteTime'), headFlag(head)));
  def('GetNoteBeat', (n, head) => {
    const b = native('noteBeat', nid(n, 1, 'GetNoteBeat'), headFlag(head));
    if (b === undefined) throw rtErr('GetNoteBeat: invalid note');
    return beatTable(b);
  });
  def('GetNoteX', (n) => native('noteX', nid(n, 1, 'GetNoteX')));
  def('GetNoteWidth', (n) => native('noteW', nid(n, 1, 'GetNoteWidth')));
  def('GetNoteType', (n) => native('noteType', nid(n, 1, 'GetNoteType')));
  def('GetNoteSlideBodyCount', (n) => native('segCount', nid(n, 1, 'GetNoteSlideBodyCount')));
  def('GetNoteSlideBodyBeat', (n, i) => {
    const b = native('segBeat', nid(n, 1, 'GetNoteSlideBodyBeat'), checkInt(i, 2, 'GetNoteSlideBodyBeat'));
    if (b === undefined) throw rtErr('GetNoteSlideBodyBeat: index out of range');
    return beatTable(b);
  });
  def('GetNoteSlideBodyX', (n, i) => native('segX', nid(n, 1, 'GetNoteSlideBodyX'), checkInt(i, 2, 'GetNoteSlideBodyX')));
  def('GetNoteFlag', () => 0);
  def('GetNoteGroup', () => 0);
  // 操作型プラグイン (OnClick / OnDragStart / OnDragMove) の中で、いま触れているレーン上の位置
  def('GetClickX', () => native('clickX'));
  def('GetClickBeat', () => beatTable(native('clickBeat')));
  def('GetClickBeatFree', () => beatTable(native('clickBeatFree')));

  // ----- BPM・エフェクト -----
  def('GetTimeCount', () => native('timeCount'));
  def('GetTimeAt', (i) => {
    const r = native('timeAt', checkInt(i, 1, 'GetTimeAt'));
    if (r === undefined) return undefined;
    const t = new LuaTable();
    t.set('beat', beatTable([r[0], r[1], r[2]]));
    t.set('bpm', r[3]);
    return t;
  });
  def('GetEffectCount', () => native('effectCount'));
  def('GetEffectAt', (i) => {
    const r = native('effectAt', checkInt(i, 1, 'GetEffectAt'));
    if (r === undefined) return undefined;
    const t = new LuaTable();
    t.set('beat', beatTable([r[0], r[1], r[2]]));
    t.set('kind', r[3]);
    t.set('value', r[4]);
    t.set(r[3], r[4]);
    return t;
  });
  def('AddTime', (beat, bpm) => { native('addTime', ...beatArr(beat, 1, 'AddTime'), num(bpm, 2, 'AddTime')); });
  def('DeleteTime', (i) => { native('delTime', checkInt(i, 1, 'DeleteTime')); });
  def('AddEffect', (beat, a, b) => {
    let kind = 'scroll', value = 1;
    if (typeof a === 'string') { kind = a; if (b !== undefined) value = num(b, 3, 'AddEffect'); }
    else if (a !== undefined) { value = num(a, 2, 'AddEffect'); if (typeof b === 'string') kind = b; }
    native('addEffect', ...beatArr(beat, 1, 'AddEffect'), kind, value);
  });
  def('DeleteEffect', (i) => { native('delEffect', checkInt(i, 1, 'DeleteEffect')); });

  // ----- ノーツの編集 -----
  def('StartBatch', () => { native('batch', true); });
  def('FinishBatch', () => { native('batch', false); });
  def('AddNote', (type) => ref(native('addNote', type === undefined ? 1 : checkInt(type, 1, 'AddNote'))));
  def('DeleteNote', (n) => { native('deleteNote', nid(n, 1, 'DeleteNote')); });
  def('SetNoteBeat', (n, beat) => { native('setNoteBeat', nid(n, 1, 'SetNoteBeat'), ...beatArr(beat, 2, 'SetNoteBeat')); });
  def('SetNoteX', (n, x) => { native('setNoteX', nid(n, 1, 'SetNoteX'), num(x, 2, 'SetNoteX')); });
  def('SetNoteWidth', (n, w) => { native('setNoteW', nid(n, 1, 'SetNoteWidth'), num(w, 2, 'SetNoteWidth')); });
  // AddNoteSlideBody: beat の順になる位置に挿入して、その位置 (0 始まり) を返す (本物の Malody と同じ)。同じ beat なら、あとから足したほうが後ろ
  def('AddNoteSlideBody', (n, beat) => native('addSeg', nid(n, 1, 'AddNoteSlideBody'), ...beatArr(beat, 2, 'AddNoteSlideBody')));
  // このエディタ独自: 並べ替えず、足した順のまま末尾に足す (beat が行ったり来たりする「バグスライド」を作るとき用)
  def('AppendNoteSlideBody', (n, beat) => native('appendSeg', nid(n, 1, 'AppendNoteSlideBody'), ...beatArr(beat, 2, 'AppendNoteSlideBody')));
  def('SetNoteSlideBodyX', (n, i, x) => {
    native('setSegX', nid(n, 1, 'SetNoteSlideBodyX'), checkInt(i, 2, 'SetNoteSlideBodyX'), num(x, 3, 'SetNoteSlideBodyX'));
  });
  def('DeleteNoteSlideBody', (n, i) => {
    native('delSeg', nid(n, 1, 'DeleteNoteSlideBody'), i === undefined ? null : checkInt(i, 2, 'DeleteNoteSlideBody'));
  });
  def('SelectNote', (n, flag) => { native('select', nid(n, 1, 'SelectNote'), flag === undefined ? true : T(flag)); });
  def('SetGridLine', (n) => { native('setGrid', checkInt(n, 1, 'SetGridLine')); });
  def('SeekTo', (beat) => { native('seekTo', ...beatArr(beat, 1, 'SeekTo')); });

  // ----- Beat 計算 -----
  def('MakeBeat', (a, b, c) => {
    if (a instanceof LuaTable) return beatTable(beatNorm(...beatArr(a, 1, 'MakeBeat')));
    if (b === undefined && typeof a === 'number') return beatTable(beatNorm(0, Math.round(a * 1048576), 1048576));
    return beatTable(beatNorm(optNum(a, 0, 1, 'MakeBeat'), optNum(b, 0, 2, 'MakeBeat'), optNum(c, 1, 3, 'MakeBeat')));
  });
  def('BeatAdd', (a, b) => beatTable(beatCombine(beatArr(a, 1, 'BeatAdd'), beatArr(b, 2, 'BeatAdd'), 1)));
  def('BeatMinus', (a, b) => beatTable(beatCombine(beatArr(a, 1, 'BeatMinus'), beatArr(b, 2, 'BeatMinus'), -1)));

  // ----- 画面表示・入力 -----
  def('ShowMessage', (s) => { native('message', tostr(s)); });
  def('ShowTip', (s) => { native('tip', tostr(s)); });
  def('GetUserInput', (title, dflt) => native('input', title === undefined ? '' : tostr(title), dflt === undefined ? '' : tostr(dflt)));

  // ----- スプライト (レーンの上に画像を重ねる。操作型プラグインのつまみなど) -----
  //   モジュールの .Beat (拍の表) / .X (中心。レーン幅に対する %) / .Width (幅。レーン幅に対する %) を書き換えると、すぐ画面に反映される
  const modules = new Map();
  const moduleValue = (v) => {
    if (v instanceof LuaTable) { const b = beatArr(v, 1, 'module'); return b; }
    if (typeof v === 'number' || typeof v === 'string' || typeof v === 'boolean') return v;
    return null;
  };
  const makeModule = (name) => {
    const props = new Map();
    const mod = new LuaTable();
    const meta = new LuaTable();
    meta.set('__index', function (t, k) { return [props.get(k)]; });
    meta.set('__newindex', function (t, k, v) {
      props.set(k, v);
      if (typeof k === 'string') native('spriteSet', name, k, moduleValue(v));
      return EMPTY;
    });
    mod.meta = meta;
    return mod;
  };
  def('AddSprite', (name, image) => {
    const key = tostr(name);
    native('spriteAdd', key, tostr(image));
    let m = modules.get(key);
    if (m === undefined) { m = makeModule(key); modules.set(key, m); }
    return m;
  });
  def('FindModule', (name) => modules.get(tostr(name)));
  def('RemoveModule', (name) => {
    const key = tostr(name);
    native('spriteRemove', key);
    modules.delete(key);
  });

  // ----- まだ対応していない API (呼ばれたら画面で知らせる) -----
  const unsupported = ['SetNoteFlag', 'SetNoteGroup', 'WriteFilePlugin', 'ReadFileSelect', 'ReadBytesSelect',
    'ReadData', 'WriteData', 'WriteChartCustom', 'CallShortcut', 'GetUserSelect', 'GetUserOption',
    'AddText', 'AddSpriteUndo', 'AddTextUndo', 'RemoveSpriteUndo'];
  for (const name of unsupported) {
    Ed.set(name, function () { native('unsupported', name); return [undefined]; });
  }
  return Ed;
}

// ============================================================
// Swift から呼ぶ入口
// ============================================================
let sessionG = null;          // 操作型プラグインの実行中の環境 (OnActive …… OnDeactive の間、保たれる)
let sessionChunk = '?';

function newSession(chunk) {
  R.chunk = chunk;
  R.ln = 0;
  R.fuel = 20000;
  const printFn = (text, noNewline) => { native('log', noNewline ? text : text + '\n'); };
  const G = makeGlobals(printFn);
  G.set('Editor', makeEditor());
  R.G = G;
  return G;
}

function execChunk(src, chunk) {
  const G = newSession(chunk);
  const f = compileLua(src, chunk, G);
  f();
  return G;
}

function errText(e) {
  const v = errorValue(e);
  if (typeof v === 'string') return v;
  if (typeof v === 'number') return numstr(v);
  if (v instanceof LuaTable) {
    const m = v.get('message') || v.get('msg');
    return typeof m === 'string' ? m : '(error object is a table value)';
  }
  return tostr(v);
}

const metaStr = (v) => (typeof v === 'string' ? v : (typeof v === 'number' ? numstr(v) : ''));
const metaNum = (v) => (typeof v === 'number' ? v : (typeof v === 'string' && str2num(v) !== undefined ? str2num(v) : null));

const TOOL_EVENTS = ['OnActive', 'OnDeactive', 'OnClick', 'OnDragStart', 'OnDragMove', 'OnDragEnd'];

const LuaHost = {
  // list: JSON  [{id, name, src}]  ->  JSON [{id, ok, name, mode, type, require, hasRun, error}]
  inspect(listJSON) {
    const list = JSON.parse(listJSON);
    const out = [];
    for (const item of list) {
      try {
        const G = execChunk(item.src, item.name);
        out.push({
          id: item.id, ok: true,
          name: metaStr(G.get('PluginName')),
          mode: metaNum(G.get('PluginMode')),
          type: metaNum(G.get('PluginType')),
          require: metaStr(G.get('PluginRequire')),
          hasRun: typeof G.get('Run') === 'function',
          hasTool: TOOL_EVENTS.some((n) => typeof G.get(n) === 'function'),
          icon: metaStr(G.get('PluginIcon')),
          error: ''
        });
      } catch (e) {
        if (e instanceof LuaAbort) throw e;
        out.push({ id: item.id, ok: false, name: '', mode: null, type: null, require: '', hasRun: false, hasTool: false, icon: '', error: errText(e) });
      }
    }
    return JSON.stringify(out);
  },
  // 操作型プラグイン (PluginType 2): 読み込んで環境を保つ。あとは call('OnActive') などでイベントを1つずつ呼ぶ
  start(src, chunk) {
    try {
      sessionG = execChunk(src, chunk);
      sessionChunk = chunk;
      return JSON.stringify({ ok: true });
    } catch (e) {
      sessionG = null;
      if (e instanceof LuaAbort) return JSON.stringify({ ok: false, aborted: true, error: '' });
      return JSON.stringify({ ok: false, error: errText(e) });
    }
  },
  call(name) {
    if (sessionG === null) return JSON.stringify({ ok: false, error: 'プラグインが読み込まれていません' });
    const f = sessionG.get(name);
    if (typeof f !== 'function') return JSON.stringify({ ok: true, called: false });
    try {
      R.chunk = sessionChunk;
      R.ln = 0;
      R.fuel = 20000;
      call(f);
      return JSON.stringify({ ok: true, called: true });
    } catch (e) {
      if (e instanceof LuaAbort) return JSON.stringify({ ok: false, called: true, aborted: true, error: '' });
      return JSON.stringify({ ok: false, called: true, error: errText(e) });
    }
  },
  stop() {
    sessionG = null;
    return 'ok';
  },
  run(src, chunk) {
    try {
      const G = execChunk(src, chunk);
      const run = G.get('Run');
      if (typeof run !== 'function') return JSON.stringify({ ok: false, error: chunk + ': Run() 関数が定義されていません' });
      call(run);
      return JSON.stringify({ ok: true });
    } catch (e) {
      if (e instanceof LuaAbort) return JSON.stringify({ ok: false, aborted: true, error: '' });
      return JSON.stringify({ ok: false, error: errText(e) });
    }
  }
};

// ============================================================
// zip の解凍 (プラグインのパッケージ: .lua + 画像)
//   Swift には zip を読む部品が無いので、ここで deflate の解凍まで行う。
//   データは base64 で受け渡す (JavaScriptCore には atob / btoa / TextDecoder が無い)
// ============================================================
const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
const B64_REV = (function () {
  const t = new Int16Array(256).fill(-1);
  for (let i = 0; i < 64; i++) t[B64.charCodeAt(i)] = i;
  return t;
})();

function b64decode(s) {
  const clean = s.replace(/[^A-Za-z0-9+/]/g, '');
  const n = clean.length;
  const out = new Uint8Array(Math.floor(n * 3 / 4));
  let o = 0, acc = 0, bits = 0;
  for (let i = 0; i < n; i++) {
    acc = (acc << 6) | B64_REV[clean.charCodeAt(i)];
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[o++] = (acc >> bits) & 0xFF;
    }
  }
  return out.subarray(0, o);
}

function b64encode(bytes) {
  let out = '';
  const n = bytes.length;
  for (let i = 0; i < n; i += 3) {
    const a = bytes[i], b = i + 1 < n ? bytes[i + 1] : 0, c = i + 2 < n ? bytes[i + 2] : 0;
    out += B64[a >> 2] + B64[((a & 3) << 4) | (b >> 4)];
    out += i + 1 < n ? B64[((b & 15) << 2) | (c >> 6)] : '=';
    out += i + 2 < n ? B64[c & 63] : '=';
  }
  return out;
}

function utf8decode(bytes) {
  let s = '';
  for (let i = 0; i < bytes.length;) {
    const c = bytes[i++];
    if (c < 0x80) s += String.fromCharCode(c);
    else if (c >= 0xC0 && c < 0xE0 && i < bytes.length) s += String.fromCharCode(((c & 0x1F) << 6) | (bytes[i++] & 0x3F));
    else if (c >= 0xE0 && c < 0xF0 && i + 1 < bytes.length) { s += String.fromCharCode(((c & 0x0F) << 12) | ((bytes[i] & 0x3F) << 6) | (bytes[i + 1] & 0x3F)); i += 2; }
    else if (c >= 0xF0 && i + 2 < bytes.length) { s += String.fromCodePoint(((c & 0x07) << 18) | ((bytes[i] & 0x3F) << 12) | ((bytes[i + 1] & 0x3F) << 6) | (bytes[i + 2] & 0x3F)); i += 3; }
    else s += '?';
  }
  return s;
}

const CRC_TABLE = (function () {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    t[n] = c >>> 0;
  }
  return t;
})();
function crc32(bytes) {
  let c = 0xFFFFFFFF;
  for (let i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]) & 0xFF] ^ (c >>> 8);
  return (c ^ 0xFFFFFFFF) >>> 0;
}

// ---- deflate (RFC 1951)。zlib の puff.c と同じ、符号を1ビットずつ読む素直な方式 ----
const LBASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
const LEXT = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
const DBASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577];
const DEXT = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
const CL_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

function huffman(lengths, n) {
  const count = new Int16Array(16), symbol = new Int16Array(n), offs = new Int16Array(16);
  for (let i = 0; i < n; i++) count[lengths[i]]++;
  for (let len = 1; len < 15; len++) offs[len + 1] = offs[len] + count[len];
  for (let i = 0; i < n; i++) if (lengths[i] !== 0) symbol[offs[lengths[i]]++] = i;
  return { count, symbol };
}

let FIXED = null;
function fixedTables() {
  if (FIXED) return FIXED;
  const l = new Uint8Array(288);
  for (let i = 0; i < 144; i++) l[i] = 8;
  for (let i = 144; i < 256; i++) l[i] = 9;
  for (let i = 256; i < 280; i++) l[i] = 7;
  for (let i = 280; i < 288; i++) l[i] = 8;
  const d = new Uint8Array(30).fill(5);
  FIXED = { lencode: huffman(l, 288), distcode: huffman(d, 30) };
  return FIXED;
}

function inflateRaw(src, sizeHint) {
  let pos = 0, bitbuf = 0, bitcnt = 0;
  let out = new Uint8Array(Math.max(1024, sizeHint | 0));
  let outLen = 0;
  const put = (b) => {
    if (outLen >= out.length) { const bigger = new Uint8Array(out.length * 2); bigger.set(out); out = bigger; }
    out[outLen++] = b;
  };
  const bits = (need) => {
    let val = bitbuf;
    while (bitcnt < need) {
      if (pos >= src.length) throw new Error('zip: 圧縮データが途中で終わっています');
      val |= src[pos++] << bitcnt;
      bitcnt += 8;
    }
    bitbuf = val >>> need;
    bitcnt -= need;
    return val & ((1 << need) - 1);
  };
  const decode = (h) => {
    let code = 0, first = 0, index = 0;
    for (let len = 1; len <= 15; len++) {
      code |= bits(1);
      const count = h.count[len];
      if (code - count < first) return h.symbol[index + (code - first)];
      index += count;
      first += count;
      first <<= 1;
      code <<= 1;
    }
    throw new Error('zip: 圧縮データが壊れています');
  };
  const codes = (lencode, distcode) => {
    for (;;) {
      let sym = decode(lencode);
      if (sym < 256) put(sym);
      else if (sym === 256) return;
      else {
        sym -= 257;
        if (sym >= 29) throw new Error('zip: 圧縮データが壊れています');
        const len = LBASE[sym] + bits(LEXT[sym]);
        const ds = decode(distcode);
        if (ds >= 30) throw new Error('zip: 圧縮データが壊れています');
        const dist = DBASE[ds] + bits(DEXT[ds]);
        if (dist > outLen) throw new Error('zip: 圧縮データが壊れています');
        for (let k = 0; k < len; k++) put(out[outLen - dist]);
      }
    }
  };
  let last;
  do {
    last = bits(1);
    const type = bits(2);
    if (type === 0) {
      bitbuf = 0; bitcnt = 0;
      if (pos + 4 > src.length) throw new Error('zip: 圧縮データが途中で終わっています');
      const len = src[pos] | (src[pos + 1] << 8);
      pos += 4;
      if (pos + len > src.length) throw new Error('zip: 圧縮データが途中で終わっています');
      for (let i = 0; i < len; i++) put(src[pos + i]);
      pos += len;
    } else if (type === 1) {
      const f = fixedTables();
      codes(f.lencode, f.distcode);
    } else if (type === 2) {
      const nlen = bits(5) + 257, ndist = bits(5) + 1, ncode = bits(4) + 4;
      if (nlen > 286 || ndist > 30) throw new Error('zip: 圧縮データが壊れています');
      const lengths = new Uint8Array(320);
      for (let i = 0; i < ncode; i++) lengths[CL_ORDER[i]] = bits(3);
      const clh = huffman(lengths, 19);
      let idx = 0;
      const all = new Uint8Array(nlen + ndist);
      while (idx < nlen + ndist) {
        let sym = decode(clh);
        if (sym < 16) all[idx++] = sym;
        else {
          let prev = 0, rep;
          if (sym === 16) {
            if (idx === 0) throw new Error('zip: 圧縮データが壊れています');
            prev = all[idx - 1];
            rep = 3 + bits(2);
          } else if (sym === 17) rep = 3 + bits(3);
          else rep = 11 + bits(7);
          if (idx + rep > nlen + ndist) throw new Error('zip: 圧縮データが壊れています');
          while (rep--) all[idx++] = prev;
        }
      }
      codes(huffman(all.subarray(0, nlen), nlen), huffman(all.subarray(nlen), ndist));
    } else {
      throw new Error('zip: 圧縮データが壊れています');
    }
  } while (!last);
  return out.subarray(0, outLen);
}

// ---- zip の構造 (中央ディレクトリ → 各ファイル)。flag bit3 (データ記述子) のファイルも、中央ディレクトリのサイズで読む ----
const u16 = (b, o) => b[o] | (b[o + 1] << 8);
const u32 = (b, o) => (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) >>> 0;

function unzipBytes(zip) {
  let eocd = -1;
  for (let i = zip.length - 22; i >= Math.max(0, zip.length - 22 - 65535); i--) {
    if (zip[i] === 0x50 && zip[i + 1] === 0x4B && zip[i + 2] === 5 && zip[i + 3] === 6) { eocd = i; break; }
  }
  if (eocd < 0) throw new Error('zip ファイルではありません');
  const count = u16(zip, eocd + 10);
  let p = u32(zip, eocd + 16);
  const files = [];
  let total = 0;
  for (let n = 0; n < count; n++) {
    if (u32(zip, p) !== 0x02014B50) throw new Error('zip: 中央ディレクトリが壊れています');
    const flags = u16(zip, p + 8), method = u16(zip, p + 10);
    const crc = u32(zip, p + 16), csize = u32(zip, p + 20), usize = u32(zip, p + 24);
    const nlen = u16(zip, p + 28), elen = u16(zip, p + 30), clen = u16(zip, p + 32);
    const lho = u32(zip, p + 42);
    const nameBytes = zip.subarray(p + 46, p + 46 + nlen);
    let name = utf8decode(nameBytes).replace(/\\/g, '/');
    p += 46 + nlen + elen + clen;
    if (name.endsWith('/')) continue;                                   // フォルダ
    if (name.indexOf('__MACOSX/') === 0 || name.split('/').pop() === '.DS_Store') continue;
    const parts = name.split('/');
    if (name[0] === '/' || parts.indexOf('..') >= 0) throw new Error('zip: 不正なファイル名があります (' + name + ')');
    if ((flags & 1) !== 0) throw new Error('zip: パスワード付きの zip は読めません');
    if (u32(zip, lho) !== 0x04034B50) throw new Error('zip: ファイルの位置が壊れています');
    const dataStart = lho + 30 + u16(zip, lho + 26) + u16(zip, lho + 28);
    if (dataStart + csize > zip.length) throw new Error('zip: ファイルが途中で終わっています');
    total += usize;
    if (total > 64 * 1024 * 1024) throw new Error('zip: 展開すると大きすぎます (64MB まで)');
    const raw = zip.subarray(dataStart, dataStart + csize);
    let data;
    if (method === 0) data = raw;
    else if (method === 8) data = inflateRaw(raw, usize);
    else throw new Error('zip: 対応していない圧縮方式です (' + name + ')');
    if (data.length !== usize) throw new Error('zip: ' + name + ' のサイズが合いません');
    if (crc32(data) !== crc) throw new Error('zip: ' + name + ' が壊れています (CRC が合いません)');
    files.push({ name, data });
  }
  return files;
}

// Swift から: base64 の zip -> JSON {ok, files:[{name, data(base64)}], error}
LuaHost.unzip = function (zipBase64) {
  try {
    const files = unzipBytes(b64decode(zipBase64));
    return JSON.stringify({ ok: true, files: files.map((f) => ({ name: f.name, data: b64encode(f.data) })) });
  } catch (e) {
    return JSON.stringify({ ok: false, files: [], error: String(e && e.message ? e.message : e) });
  }
};
LuaHost._zip = { unzipBytes, inflateRaw, b64decode, b64encode, crc32, utf8decode };    // テスト用

root.LuaHost = LuaHost;
root.__LuaDebug = { compileLua: compileLua, lastJS: function () { return R.lastJS; }, LuaTable: LuaTable, tostr: tostr };
})(typeof globalThis !== 'undefined' ? globalThis : this);

"""##
}
