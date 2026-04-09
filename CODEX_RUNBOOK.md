# Codex Bugfix Runbook

这套模板只给 Codex 使用，目标是对 `swe_bench_pro_js_ts_basic_10.json` 里的每个 bug 进行两轮独立修复。

## 目标

对同一个 bug 执行两轮修复：

1. `no_skill`
不使用 `claw-skills`

2. `with_skill`
新开一个全新 session，使用你指定的 skill

最终产物：

- `patches/no_skill/<instance_id>/fix.patch`
- `patches/with_skill/<instance_id>/result.json`
- 如果第二轮产生 patch，还会额外落 `patches/with_skill/<instance_id>/fix.patch`

仓库来源：

- 首次使用时预克隆到 `repo_cache/<owner>__<repo>/`
- 缓存格式是裸 mirror 仓库，不做工作区检出
- 后续每轮从本地 mirror 克隆工作副本并回退到目标 `base_commit`
- 不再为每个 bug 重复 clone

## 硬门控

这些规则由 `run_codex_bugfixes.sh` 同时通过目录隔离、参数隔离、日志扫描和结果校验来执行。

1. 只允许读取 `basic` 数据
脚本只会从 [swe_bench_pro_js_ts_basic_10.json](/Users/jundi/PyCharmMiscProject/autorun/swe_bench_pro_js_ts_basic_10.json) 提取单条 bug 信息，并写入每轮独立目录下的 `input/basic_bug.json`。

2. 禁止 `full` 数据
如果当前目录存在 `swe_bench_pro_js_ts_full_10.json`，脚本直接拒绝运行。

3. 第一轮禁止 `claw-skills`
`no_skill` 轮不会把 `CLAW_SKILLS_ROOT` 暴露给 Codex，并且会扫描事件日志；一旦日志中出现该路径，整轮作废。

4. 第二轮必须显式使用 skill
`with_skill` 轮固定使用 `SECOND_PASS_SKILL_PATH`。脚本会把 `CLAW_SKILLS_ROOT` 作为可访问目录暴露给 Codex，并要求 Codex 在结构化结果里回填 `used_skill_path`；若不匹配，整轮作废。

5. 每轮必须是新 session
脚本每次都调用新的 `codex exec`，不会复用上一次 session。

6. 第一轮必须落盘 patch，第二轮 patch 可选
`no_skill` 必须在独立运行目录里生成 `out/fix.patch`，随后脚本会校验其非空且可 `git apply --check`，最后复制到正式产物目录。
`with_skill` 允许“流程跑完但没有 patch”；这种情况下只要求 `result.json` 落盘。

7. 不允许只输出分析
Codex 的最终输出被 JSON Schema 约束。
`no_skill` 只接受 `status="patched"`。
`with_skill` 接受 `status="patched"` 或 `status="failed"`，其中 `failed` 表示本轮完成但未产出 patch。

## 目录约定

脚本运行后会创建这些目录：

- `repo_cache/<owner>__<repo>/`
- `runs/<instance_id>/<pass_mode>/attempt-<n>/`
- `logs/<pass_mode>/`
- `patches/no_skill/<instance_id>/`
- `patches/with_skill/<instance_id>/`

每个 attempt 目录里会有：

- `input/basic_bug.json`
- `repo/`
- `out/fix.patch`（可选；`with_skill` 可能没有）
- `prompt.md`
- `result.json`
- `events.jsonl`

## 默认路径与环境变量

脚本里的本地路径全部采用“默认值 + 环境变量覆盖”的模式。

默认推断规则：

- `CLAW_SKILLS_ROOT`
  脚本会优先在这些位置里找第一个存在的目录：
  - `$HOME/PycharmProjects/claw-skills`
  - `$HOME/PyCharmProjects/claw-skills`
  - `$(dirname "$ROOT_DIR")/claw-skills`
  - `$(dirname "$ROOT_DIR")/../PycharmProjects/claw-skills`
  - `$(dirname "$ROOT_DIR")/../PyCharmProjects/claw-skills`

- `SECOND_PASS_SKILL_PATH`
  默认取：
  - `$CLAW_SKILLS_ROOT/skills/debug-orchestrator-fix/SKILL.md`

- `PATCH_CHECK_ROOT`
  脚本会优先在这些位置里找：
  - `$(dirname "$ROOT_DIR")/SWE-bench_Pro-os`
  - `$HOME/PyCharmMiscProject/SWE-bench_Pro-os`

  这里的 `SWE-bench_Pro-os` 指外部评测项目目录。
  当前仓库不会复制 `run_single_patch_check.py` 或 `validate_single_patch.py` 进来，而是直接调用该项目里的脚本。
  也就是说，patch 校验脚本应当放在 `SWE-bench_Pro-os/helper_code/` 下，而不是放到当前 `autorun` 仓库里。

- `PATCH_CHECK_PYTHON`
  默认取：
  - `$PATCH_CHECK_ROOT/.venv/bin/python`

- `PATCH_CHECK_SCRIPT`
  默认取：
  - `$PATCH_CHECK_ROOT/helper_code/run_single_patch_check.py`

- `SECOND_PASS_CODEX_ACP_COMMAND`
  脚本会优先在这些位置里找：
  - `$ROOT_DIR/.runtime/codex-acp/node_modules/@zed-industries/codex-acp-darwin-arm64/bin/codex-acp`
  - `/tmp/codex-acp-local/node_modules/@zed-industries/codex-acp-darwin-arm64/bin/codex-acp`

推荐覆盖方式：

```bash
export CLAW_SKILLS_ROOT="/abs/path/to/claw-skills"
export SECOND_PASS_SKILL_PATH="$CLAW_SKILLS_ROOT/skills/debug-orchestrator-fix/SKILL.md"
export PATCH_CHECK_ROOT="/abs/path/to/SWE-bench_Pro-os"
export PATCH_CHECK_PYTHON="$PATCH_CHECK_ROOT/.venv/bin/python"
export PATCH_CHECK_SCRIPT="$PATCH_CHECK_ROOT/helper_code/run_single_patch_check.py"
export SECOND_PASS_CODEX_ACP_COMMAND="/abs/path/to/codex-acp"
```

## 运行前准备

1. 确保 [swe_bench_pro_js_ts_basic_10.json](/Users/jundi/PyCharmMiscProject/autorun/swe_bench_pro_js_ts_basic_10.json) 存在
2. 先执行一次：

```bash
./clone_all_repos.sh
```

3. 确保当前目录没有 `swe_bench_pro_js_ts_full_10.json`
4. 确保本机有：
   `codex`
   `jq`
   `git`
5. 确保第二轮 skill 路径可解析：
   `SECOND_PASS_SKILL_PATH`
6. 如果第二轮 agent 是 `codex`，确保 `SECOND_PASS_CODEX_ACP_COMMAND` 指向可执行的 `codex-acp`
7. 如果开启 patch 校验，确保外部 `SWE-bench_Pro-os` 项目已就绪，并且下面两个文件存在于那个项目中：
   - `$PATCH_CHECK_ROOT/.venv/bin/python`
   - `$PATCH_CHECK_ROOT/helper_code/run_single_patch_check.py`

特别说明：

- `run_codex_bugfixes.sh` 不会把 patch check 脚本复制到当前仓库
- 它只会通过 `PATCH_CHECK_ROOT` / `PATCH_CHECK_SCRIPT` 去调用 `SWE-bench_Pro-os` 项目里的脚本
- 所以这部分依赖应该维护在 `SWE-bench_Pro-os` 项目里

最小推荐环境：

```bash
export CLAW_SKILLS_ROOT="/abs/path/to/claw-skills"
export SECOND_PASS_SKILL_PATH="$CLAW_SKILLS_ROOT/skills/debug-orchestrator-fix/SKILL.md"
export SECOND_PASS_CODEX_ACP_COMMAND="/abs/path/to/codex-acp"
```

## 运行方式

跑全部 10 个 bug：

```bash
./run_codex_bugfixes.sh
```

先把涉及仓库全部预热到本地 mirror 缓存：

```bash
./run_codex_bugfixes.sh --warm-cache
```

只跑指定 bug：

```bash
./run_codex_bugfixes.sh instance_NodeBB__NodeBB-04998908ba6721d64eba79ae3b65a351dcfbc5b5-vnan
```

多个 bug：

```bash
./run_codex_bugfixes.sh <instance_id_1> <instance_id_2>
```

可选环境变量：

```bash
export MODEL="gpt-5.4"
export MAX_ATTEMPTS=2
export BASIC_JSON="$PWD/swe_bench_pro_js_ts_basic_10.json"
export CLAW_SKILLS_ROOT="/abs/path/to/claw-skills"
export SECOND_PASS_SKILL_PATH="$CLAW_SKILLS_ROOT/skills/debug-orchestrator-fix/SKILL.md"
export SECOND_PASS_CODEX_ACP_COMMAND="/abs/path/to/codex-acp"
export PATCH_CHECK_ROOT="/abs/path/to/SWE-bench_Pro-os"
export PATCH_CHECK_PYTHON="$PATCH_CHECK_ROOT/.venv/bin/python"
export PATCH_CHECK_SCRIPT="$PATCH_CHECK_ROOT/helper_code/run_single_patch_check.py"
```

## 脚本保证的事

1. 每个 bug 的两轮修复都用全新 session
2. 两轮修复使用全新 repo 工作副本，不复用前一轮工作区
3. 第一轮显式禁止 `claw-skills`
4. 第二轮显式要求 skill 路径匹配
5. 第一轮 patch 强制校验，第二轮 patch 可选
6. 第二轮至少会落 `result.json`
7. 仓库只在首次运行时 clone 到 `repo_cache` 裸 mirror，后续只做本地派生与回退

## 不能保证的事

1. 不能保证 patch 一定语义正确，只能保证流程和产物约束
2. 不能百分之百证明 Codex 没有“想过”去看 full，但脚本已经从输入、可访问目录、日志和结果四层做了约束
3. 第二轮“使用 skill”的效果强依赖你给的具体 skill 质量
