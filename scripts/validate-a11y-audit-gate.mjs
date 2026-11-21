#!/usr/bin/env node
//
// scripts/hooks/a11y-audit-gate.mjs 的回归测试（#732）。
//
// 为什么需要它：这道检查两个方向都会静默坏掉 —— 判据放宽，没跑审计的分支就推得上去；
// 「同一份欠账只拦一次」坏掉，每次 push 都被拦，然后被 `--no-verify` 绕开。两种都不报错。

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const gate = path.resolve(import.meta.dirname, 'hooks/a11y-audit-gate.mjs');
const scratches = [];

const VIEW = 'struct HomeView: View {\n  var body: some View { Text("x") }\n}\n';

// 临时仓库：origin/main 停在种子提交，再开一条分支提交 files。
function scratchBranch(files, branch = 'feat/x') {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'aidrun-a11y-gate-'));
  scratches.push(dir);
  const g = (...args) =>
    spawnSync('git', ['-c', 'user.email=t@t', '-c', 'user.name=t', '-c', 'commit.gpgsign=false', ...args], {
      cwd: dir,
      encoding: 'utf8',
    });
  g('init', '-q');
  fs.writeFileSync(path.join(dir, 'seed.txt'), 'seed\n');
  g('add', '-A');
  g('commit', '-qm', 'seed');
  g('update-ref', 'refs/remotes/origin/main', g('rev-parse', 'HEAD').stdout.trim());
  g('checkout', '-qb', branch);
  for (const [f, text] of Object.entries(files)) {
    fs.mkdirSync(path.join(dir, path.dirname(f)), { recursive: true });
    fs.writeFileSync(path.join(dir, f), text);
  }
  g('add', '-A');
  g('commit', '-qm', 'feat: 改动');
  return { dir, g };
}

const run = (dir, ...args) =>
  spawnSync('node', [gate, ...args], { encoding: 'utf8', env: { ...process.env, AIDRUN_REPO_ROOT: dir } });

const cases = [
  {
    name: '改了视图、没有审计运行记录 → 第一次拦（exit 1），同一份欠账第二次放行但明说没跑（exit 3）',
    check: () => {
      const { dir } = scratchBranch({ 'blindRun/Feature/HomeView.swift': VIEW });
      const first = run(dir, 'check');
      if (first.status !== 1) return `第一次期望 exit 1，实得 ${first.status}：${first.stdout}`;
      if (!first.stdout.includes('没跑无障碍审计') || !first.stdout.includes('HomeView.swift')) return `没点名欠账：${first.stdout}`;
      const second = run(dir, 'check');
      if (second.status !== 3) return `第二次期望 exit 3，实得 ${second.status}`;
      return second.stdout.includes('这不算通过') ? null : `放行时没说「这不算通过」：${second.stdout}`;
    },
  },
  {
    name: '欠账变了（又改了一个视图）→ 重新拦一次',
    check: () => {
      const { dir, g } = scratchBranch({ 'blindRun/Feature/HomeView.swift': VIEW });
      run(dir, 'check');
      fs.writeFileSync(path.join(dir, 'blindRun/Feature/OtherView.swift'), VIEW);
      g('add', '-A');
      g('commit', '-qm', 'feat: 又一个视图');
      const r = run(dir, 'check');
      return r.status === 1 ? null : `期望 exit 1，实得 ${r.status}`;
    },
  },
  {
    name: 'record 之后同一分支放行（exit 0）；别的分支的记录不算',
    check: () => {
      const { dir, g } = scratchBranch({ 'blindRun/Feature/HomeView.swift': VIEW });
      g('checkout', '-qb', 'feat/other');
      if (run(dir, 'record', 'passed').status !== 0) return 'record 没成功';
      g('checkout', '-q', 'feat/x');
      const other = run(dir, 'check');
      if (other.status !== 1) return `别的分支跑过审计，却让本分支过了（exit ${other.status}）`;
      run(dir, 'record', 'failed');
      const r = run(dir, 'check');
      if (r.status !== 0) return `本分支有记录，期望 exit 0，实得 ${r.status}`;
      return r.stdout.includes('failed') ? null : `没带出最近一次的结论：${r.stdout}`;
    },
  },
  {
    name: 'worktree 里记的审计，按分支在共用 git 目录里找得到',
    check: () => {
      const { dir, g } = scratchBranch({ 'seed2.txt': 'x\n' }, 'base');
      const wt = path.join(dir, 'wt');
      g('worktree', 'add', '-q', '-b', 'feat/wt', wt);
      fs.mkdirSync(path.join(wt, 'blindRun'), { recursive: true });
      fs.writeFileSync(path.join(wt, 'blindRun/AView.swift'), VIEW);
      spawnSync('git', ['-c', 'user.email=t@t', '-c', 'user.name=t', 'add', '-A'], { cwd: wt });
      spawnSync('git', ['-c', 'user.email=t@t', '-c', 'user.name=t', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'v'], { cwd: wt });
      if (run(wt, 'check').status !== 1) return 'worktree 里改了视图没被拦';
      if (run(wt, 'check').status !== 3) return 'worktree 里「只拦一次」没生效（.git 是文件，拼路径会写失败）';
      run(wt, 'record', 'passed');
      return run(wt, 'check').status === 0 ? null : 'worktree 里记了审计却没认出来';
    },
  },
  {
    // 判据与设计提醒钩子共用：测试目录、不含 View 声明的 .swift、blindRun/ 之外的都不算；删掉的视图也不算。
    name: '没改视图的分支静默放行：只改测试、Service、仓库别处，或删了一个视图',
    check: () => {
      const { dir, g } = scratchBranch({
        'blindRunUITests/HomeUITests.swift': VIEW,
        'blindRun/Core/OrderService.swift': 'final class OrderService {}\n',
        'scripts/x.swift': VIEW,
        'blindRun/Feature/GoneView.swift': VIEW,
      });
      // GoneView 先进 origin/main，再在分支上删掉。
      g('update-ref', 'refs/remotes/origin/main', g('rev-parse', 'HEAD').stdout.trim());
      fs.rmSync(path.join(dir, 'blindRun/Feature/GoneView.swift'));
      fs.writeFileSync(path.join(dir, 'blindRun/Core/OrderService.swift'), 'final class OrderService { }\n');
      g('add', '-A');
      g('commit', '-qm', 'refactor: 删视图、改 Service');
      const r = run(dir, 'check');
      return r.status === 0 && !r.stdout.trim() ? null : `期望 exit 0 且无输出，实得 ${r.status}：${r.stdout}`;
    },
  },
  {
    name: '没有 origin/main 时不许报通过，也不许拦死（exit 3，明说没跑）',
    check: () => {
      const { dir, g } = scratchBranch({ 'blindRun/Feature/HomeView.swift': VIEW });
      g('update-ref', '-d', 'refs/remotes/origin/main');
      const r = run(dir, 'check');
      return r.status === 3 && r.stdout.includes('这不算通过') ? null : `期望 exit 3，实得 ${r.status}：${r.stdout}`;
    },
  },
];

let failed = 0;
for (const c of cases) {
  let err;
  try {
    err = c.check();
  } catch (e) {
    err = `抛异常：${e.message}`;
  }
  if (err) {
    console.error(`✗ ${c.name}\n  ${err}`);
    failed += 1;
  } else {
    console.log(`✓ ${c.name}`);
  }
}

for (const dir of scratches) fs.rmSync(dir, { recursive: true, force: true });

if (failed) {
  console.error(`\n${failed} 条失败。`);
  process.exit(1);
}
console.log(`\n${cases.length} 条全部通过。`);
