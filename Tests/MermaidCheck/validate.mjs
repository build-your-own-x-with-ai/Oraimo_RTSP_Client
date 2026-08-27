// 用 VS Code 自带的那份 mermaid 校验文档里的图。
//
// 为什么用这一份而不是 npm 装：报错的就是它。VS Code 预览失败时抛的那串
// token 列表，跟这里抛的逐字一致，所以它说过就是真的能渲染。npm 上的版本
// 可能新可能旧，过了也不代表编辑器里能过。而且这个项目不引第三方依赖。
//
// 用法：node validate.mjs <bundle 目录> <markdown...>
//   bundle 目录 = VS Code 的 markdown-editor-out，里面有 mermaid.core-*.js
//
// 只做 parse，不做 render：语法错误在 parse 阶段就暴露，而 render 要真实的
// DOM 去量文字宽度，在 node 里立不起来。代价是渲染期的问题这里查不出来 ——
// 比如 <foo> 这种会被当 HTML 标签消掉的写法，parse 是过的。

import { cpSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { pathToFileURL } from 'node:url';

const [, , bundleDir, ...docs] = process.argv;
if (!bundleDir || docs.length === 0) {
  console.error('用法：node validate.mjs <bundle 目录> <markdown...>');
  process.exit(2);
}

// --- 把 bundle 复制出来再打补丁，绝不动 VS Code 装的那份 ---
const work = mkdtempSync(join(tmpdir(), 'mmcheck-'));
cpSync(bundleDir, work, { recursive: true });
// 最近的 package.json 没有 type:module，node 会把 .js 当 CJS 读，而这些是 ESM
writeFileSync(join(work, 'package.json'), '{"type":"module"}\n');

const entries = readdirSync(work).filter((f) => /^mermaid\.core-.*\.js$/.test(f));
if (entries.length !== 1) {
  console.error(`bundle 目录里应有且只有一个 mermaid.core-*.js，实际 ${entries.length} 个`);
  process.exit(2);
}

// --- 补丁：bundle 内联了 DOMPurify，无真实 DOM 时它走早返回分支，
//     压根没定义 sanitize，一调用就 TypeError。文本消毒跟语法无关，短路掉。
//     按正则去掉接收者，不写死混淆名 —— VS Code 升级后那个名字会变。 ---
let patched = 0;
for (const f of readdirSync(work).filter((f) => f.endsWith('.js'))) {
  const p = join(work, f);
  const src = readFileSync(p, 'utf8');
  const out = src
    .replace(/\b[A-Za-z_$][\w$]*\.sanitize\(/g, 'String(')
    .replace(/\b[A-Za-z_$][\w$]*\.addHook\(/g, '((...a)=>{})(');
  if (out !== src) { writeFileSync(p, out); patched++; }
}
// 一处都没打上说明 bundle 结构变了，这个假设已经过期，必须当场失败而不是
// 让后面报一堆看不懂的 TypeError。Tests/build.sh 里校验 preroll 补丁同理。
if (patched === 0) {
  console.error('补丁没打上：bundle 里找不到 .sanitize( / .addHook(，结构可能变了');
  process.exit(2);
}

// --- 最小 DOM 壳：bundle 在 import 期就会摸 document ---
const el = () => ({
  style: {}, classList: { add() {}, remove() {}, contains: () => false },
  setAttribute() {}, getAttribute: () => null, removeAttribute() {},
  hasAttribute: () => false,
  appendChild(c) { return c; }, removeChild(c) { return c; }, remove() {},
  insertBefore(c) { return c; },
  querySelector: () => null, querySelectorAll: () => [],
  addEventListener() {}, removeEventListener() {},
  getBoundingClientRect: () => ({ x: 0, y: 0, width: 0, height: 0, top: 0, left: 0, right: 0, bottom: 0 }),
  getComputedTextLength: () => 0, getBBox: () => ({ x: 0, y: 0, width: 0, height: 0 }),
  firstChild: null, childNodes: [], children: [], parentNode: null,
  innerHTML: '', textContent: '',
});

const doc = {
  // 必须留在 loading。bundle 里有「文档就绪就开跑」的逻辑，给 complete
  // 会让它在 import 期直接进入渲染流程，然后卡死在立不起来的 DOM 上 ——
  // 表现是 import 永不返回，一行日志都没有，很难猜。
  readyState: 'loading',
  documentElement: el(), body: el(), head: el(), currentScript: null,
  createElement: el, createElementNS: el, createDocumentFragment: el,
  createTextNode: () => el(),
  getElementById: () => null, getElementsByTagName: () => [],
  querySelector: () => null, querySelectorAll: () => [],
  addEventListener() {}, removeEventListener() {},
};

globalThis.document = doc;
globalThis.window = {
  document: doc, location: { href: 'file:///' }, navigator: { userAgent: 'node' },
  addEventListener() {}, removeEventListener() {},
  getComputedStyle: () => ({ getPropertyValue: () => '' }),
  matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
  requestAnimationFrame: (f) => setTimeout(f, 0),
};
globalThis.self = globalThis.window;
globalThis.requestAnimationFrame = (f) => setTimeout(f, 0);
if (!globalThis.navigator) globalThis.navigator = { userAgent: 'node' };

const mermaid = (await import(pathToFileURL(join(work, entries[0])).href)).default;
mermaid.initialize({ startOnLoad: false, securityLevel: 'loose' });

/// 抽出 markdown 里的 mermaid 块，连带它在文件里的起始行号。
/// 行号要留着：报错里的行号是块内相对行，不换算的话没法直接跳过去改。
function blocksOf(text) {
  const lines = text.split('\n');
  const out = [];
  let inBlock = false, lang = null, buf = [], start = 0;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].startsWith('```')) {
      if (!inBlock) { inBlock = true; lang = lines[i].slice(3).trim(); buf = []; start = i + 2; }
      else { if (lang === 'mermaid') out.push({ start, text: buf.join('\n') }); inBlock = false; }
      continue;
    }
    if (inBlock) buf.push(lines[i]);
  }
  return { lines, blocks: out };
}

let total = 0, bad = 0;
for (const doc of docs) {
  const { lines, blocks } = blocksOf(readFileSync(doc, 'utf8'));
  console.log(`${doc}：${blocks.length} 个 mermaid 块`);
  for (const b of blocks) {
    total++;
    const kind = b.text.trim().split('\n')[0].trim();
    try {
      await mermaid.parse(b.text);
      console.log(`  ✓ 第 ${b.start} 行起  ${kind}`);
    } catch (e) {
      bad++;
      console.log(`  ✗ 第 ${b.start} 行起  ${kind}`);
      const msg = String(e && e.message ? e.message : e);
      for (const l of msg.split('\n')) console.log(`      ${l}`);
      const m = msg.match(/[Pp]arse error on line (\d+)/);
      if (m) {
        const n = b.start + parseInt(m[1], 10) - 1;
        console.log(`      → ${doc}:${n}  ${(lines[n - 1] ?? '').trim()}`);
      }
    }
  }
}

console.log(bad === 0 ? `\n全部通过（${total}/${total}）` : `\n${bad}/${total} 个块解析失败`);
process.exit(bad === 0 ? 0 : 1);
