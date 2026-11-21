#!/usr/bin/env node

// 合并前的无障碍审计检查（#732）。由 `pre-push.sh` 调 `check`，由 `device-test.sh` 调 `record`。
//
// 存在理由：这条判定原本在 Stop 钩子里（#494），按「本轮 transcript 里跑没跑过审计」判。
// 审计只能真机跑，会话中途拦没有意义 —— 它在 Stop 里拦了 273 次，是会话被打断的最大来源。
// 负责人 2026-11-21 定：挪到合并前，只检查一次。
//
// 合并前没有 transcript 可读，所以「跑过没有」改认一份记录：`device-test.sh` 带
// `AccessibilityAuditTests` 跑出可信结果（有用例真的执行了）时，往共用 git 目录的
// `aidrun-a11y-audit-runs` 追加一行「分支 / 时间 / 结论」。
//
//   check  —— 本分支相对 origin/main 改过 `blindRun/` 下含 View 声明的 `.swift`：
//             有本分支的记录 → 退出 0；
//             没有记录、第一次见这份欠账 → 退出 1（拦下这次 push，说清怎么办）；
//             没有记录、同一份欠账已经报过 → 退出 3（放行，但明说没跑，不算通过）。
//   record <passed|failed> —— 记一行。
//
// 视图判据与设计提醒钩子共用一份（`isSwiftUIViewEdit`）。自测 scripts/validate-a11y-audit-gate.mjs。
//
// ponytail: 记录只按分支名认，不认提交 —— 先跑审计后改视图照样放行（Stop 里那条也是这个上限）。
//           要更严时把 HEAD 提交写进记录，check 里比「最后一次改视图的提交」。
// ponytail: 不带 `-only-testing` 的全量跑不记（沿用原判据：命令里要出现 AccessibilityAuditTests）。

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

import { isSwiftUIViewEdit } from './design-direction-reminder.mjs';

// AIDRUN_REPO_ROOT 只给自测用（拿一个临时 git 仓库当靶子），生产路径永远走仓库根。
const root = process.env.AIDRUN_REPO_ROOT || path.resolve(import.meta.dirname, '../..');

const EXIT_BLOCK = 1;
const EXIT_NOT_RUN = 3;

function git(...args) {
  try {
    return execFileSync('git', args, { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch {
    return null;
  }
}

// 记录放共用 git 目录：审计在哪个 worktree 跑的都认。「报过没有」放各 worktree 自己的 git 目录。
const runsFile = () => {
  const dir = git('rev-parse', '--git-common-dir');
  return dir === null ? null : path.resolve(root, dir, 'aidrun-a11y-audit-runs');
};
const seenFile = () => {
  const p = git('rev-parse', '--git-path', 'aidrun-a11y-audit-gate-seen');
  return p === null ? null : path.resolve(root, p);
};

function readOrEmpty(file) {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch {
    return '';
  }
}

const mode = process.argv[2];
const branch = git('rev-parse', '--abbrev-ref', 'HEAD');

if (mode === 'record') {
  const verdict = process.argv[3] === 'passed' ? 'passed' : 'failed';
  const file = runsFile();
  if (branch && file) fs.appendFileSync(file, `${branch}\t${new Date().toISOString()}\t${verdict}\n`);
  process.exit(0);
}

if (mode !== 'check') {
  console.error('用法：a11y-audit-gate.mjs check | record <passed|failed>');
  process.exit(2);
}

const changed = git('diff', '--name-only', '--diff-filter=d', 'origin/main...HEAD');
if (changed === null) {
  console.log('无障碍审计检查没跑：取不到 origin/main...HEAD 的改动列表。这不算通过。');
  process.exit(EXIT_NOT_RUN);
}
const views = changed
  .split('\n')
  .filter(Boolean)
  .filter((p) => isSwiftUIViewEdit('Edit', p, readOrEmpty(path.join(root, p))));
if (!views.length) process.exit(0);

const sample = `${views.slice(0, 4).join('、')}${views.length > 4 ? ' …' : ''}`;
const runs = readOrEmpty(runsFile() || '')
  .split('\n')
  .map((l) => l.split('\t'))
  .filter((cols) => cols[0] === branch);
if (runs.length) {
  const [, at, verdict] = runs[runs.length - 1];
  console.log(`无障碍审计：分支 ${branch} 跑过（最近一次 ${at}，结论 ${verdict}）。`);
  // 跑了但有失败用例不在这里拦：失败清单 device-test.sh 当场打过，这里只管「该跑没跑」。
  process.exit(0);
}

const signature = JSON.stringify([branch, views]);
const seen = seenFile();
if (seen && readOrEmpty(seen) === signature) {
  console.log(
    `无障碍审计没跑：本分支改了 ${views.length} 个 SwiftUI 视图（${sample}），这份欠账已经报过一次，放行。` +
      '这不算通过 —— PR 描述里要写明「无障碍审计没跑」和原因。'
  );
  process.exit(EXIT_NOT_RUN);
}
if (seen) {
  try {
    fs.writeFileSync(seen, signature);
  } catch {
    // 写不进去就每次都拦，不会静默放行
  }
}
console.log(
  `没跑无障碍审计：本分支改了 ${views.length} 个 SwiftUI 视图（${sample}），` +
    '但没有带 `AccessibilityAuditTests` 的 `scripts/device-test.sh` 运行记录。\n' +
    '  · 能跑：按 skill `aidrun-ship-check` §五 跑那一页的审计用例，贴出 `passed/failed` 行和截图，再 push。\n' +
    '  · 设备不在线、或负责人定了这次不跑：在 PR 描述里写明「无障碍审计没跑」和原因，不许写成通过，然后原样再 push 一次。\n' +
    '同一份欠账只拦这一次。'
);
process.exit(EXIT_BLOCK);
