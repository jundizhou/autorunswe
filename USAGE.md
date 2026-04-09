# Autorun Usage

这份文档说明三件事：

1. 怎么生成 `swe_bench_pro_js_ts_basic_10.json`
2. 怎么预克隆项目到本地缓存
3. 怎么运行自动修复脚本

适用目录：`/Users/jundi/PyCharmMiscProject/autorun`

## 依赖

运行前至少需要这些命令：

- `jq`
- `git`
- `codex`

如果启用了 patch 基准校验，还需要：

- `/Users/jundi/PyCharmMiscProject/SWE-bench_Pro-os/.venv/bin/python`
- `/Users/jundi/PyCharmMiscProject/SWE-bench_Pro-os/helper_code/run_single_patch_check.py`
- 本地 Docker 环境

## 1. 生成 `swe_bench_pro_js_ts_basic_10.json`

当前仓库里没有现成的生成脚本，下面的命令是根据现有文件格式和脚本消费方式反推出的。

我也核对过 Hugging Face 数据页，`ScaleAI/SWE-bench_Pro` 的 viewer 页面会展示本流程需要的核心字段，包括：

- `repo`
- `instance_id`
- `base_commit`
- `problem_statement`
- `requirements`
- `interface`
- `repo_language`
- `issue_specificity`
- `issue_categories`
- `before_repo_set_cmd`
- `selected_test_files_to_run`
- `dockerhub_tag`

`run_codex_bugfixes.sh` 实际依赖的字段至少有：

- `instance_id`
- `repo`
- `base_commit`
- `problem_statement`
- `requirements`
- `repo_language`
- 以及其他你希望传给每轮 `input/basic_bug.json` 的元信息

当前样例文件是一个 JSON 数组，共 10 条，语言是 `js` 或 `ts`。

如果你手里有一个完整数据文件，例如 `swe_bench_pro_js_ts_full.json`，可以这样生成前 10 条：

```bash
jq '
  map(select(.repo_language == "js" or .repo_language == "ts"))
  | .[:10]
' /path/to/swe_bench_pro_js_ts_full.json \
  > /Users/jundi/PyCharmMiscProject/autorun/swe_bench_pro_js_ts_basic_10.json
```

如果你想只保留当前脚本明确会用到或透传的字段，可以收窄成：

```bash
jq '
  map(select(.repo_language == "js" or .repo_language == "ts"))
  | .[:10]
  | map({
      instance_id,
      repo,
      base_commit,
      problem_statement,
      requirements,
      repo_language,
      interface,
      before_repo_set_cmd,
      selected_test_files_to_run,
      dockerhub_tag,
      issue_categories,
      issue_specificity
    })
' /path/to/swe_bench_pro_js_ts_full.json \
  > /Users/jundi/PyCharmMiscProject/autorun/swe_bench_pro_js_ts_basic_10.json
```

生成后可以快速检查：

```bash
python3 - <<'PY'
import json, pathlib
p = pathlib.Path('/Users/jundi/PyCharmMiscProject/autorun/swe_bench_pro_js_ts_basic_10.json')
data = json.loads(p.read_text())
print('count =', len(data))
print('first instance =', data[0]['instance_id'])
print('languages =', sorted(set(x['repo_language'] for x in data)))
PY
```

### 1.1 让大模型从 Hugging Face 页面直接生成

除了从完整 JSON/CSV 截取，你也可以让大模型直接读取 Hugging Face 页面并生成 `swe_bench_pro_js_ts_basic_10.json`。

参考页面：

- https://huggingface.co/datasets/ScaleAI/SWE-bench_Pro
- https://huggingface.co/datasets/ScaleAI/SWE-bench_Pro/viewer/default/test?row=2

注意：

- `viewer/default/test?row=2` 只是定位到第 3 行的入口页面，不代表只取这一行
- 你需要让模型继续在同一个 `test` split 里读取前 10 条或你指定的 10 条记录
- 生成结果必须是一个 JSON 数组，字段名需要与当前脚本兼容

可以直接给大模型这样的指令：

```text
读取 https://huggingface.co/datasets/ScaleAI/SWE-bench_Pro/viewer/default/test?row=2
和同一数据集 test split 的前 10 条 JS/TS 记录。

请生成一个 JSON 数组文件，命名为 swe_bench_pro_js_ts_basic_10.json。

每条记录至少保留这些字段：
instance_id
repo
base_commit
problem_statement
requirements
interface
repo_language
issue_specificity
issue_categories
before_repo_set_cmd
selected_test_files_to_run
dockerhub_tag

要求：
1. 只保留 repo_language 为 js 或 ts 的样本
2. 最终输出必须是合法 JSON，不要带 Markdown 代码块
3. 总共保留 10 条
```

生成之后，再执行一次本地校验：

```bash
python3 - <<'PY'
import json, pathlib
p = pathlib.Path('/Users/jundi/PyCharmMiscProject/autorun/swe_bench_pro_js_ts_basic_10.json')
data = json.loads(p.read_text())
assert isinstance(data, list)
assert len(data) == 10
required = {
    'instance_id', 'repo', 'base_commit', 'problem_statement',
    'requirements', 'interface', 'repo_language',
    'issue_specificity', 'issue_categories',
    'before_repo_set_cmd', 'selected_test_files_to_run', 'dockerhub_tag',
}
for i, row in enumerate(data):
    missing = sorted(required - row.keys())
    if missing:
        raise SystemExit(f'row {i} missing fields: {missing}')
    if row['repo_language'] not in {'js', 'ts'}:
        raise SystemExit(f'row {i} has unexpected repo_language: {row["repo_language"]}')
print('basic_10 json looks valid')
PY
```

## 2. 克隆项目到本地缓存

脚本不会直接在远端仓库上工作，而是先把 `BASIC_JSON` 里涉及到的唯一仓库列表克隆到本地缓存目录：

- 输入：`swe_bench_pro_js_ts_basic_10.json`
- 输出：`repo_cache/<owner>__<repo>/`
- 格式：bare mirror 仓库

执行命令：

```bash
cd /Users/jundi/PyCharmMiscProject/autorun
./clone_all_repos.sh
```

默认行为：

- 从 `swe_bench_pro_js_ts_basic_10.json` 读取所有 `.repo`
- 对 repo 去重后逐个执行 `git clone --mirror`
- 如果缓存已存在且健康，则执行 `git remote update --prune`
- 克隆日志写入 `logs/repo_clone/`

可选环境变量：

```bash
export BASIC_JSON="/Users/jundi/PyCharmMiscProject/autorun/swe_bench_pro_js_ts_basic_10.json"
export REPO_CACHE_DIR="/Users/jundi/PyCharmMiscProject/autorun/repo_cache"
export LOG_DIR="/Users/jundi/PyCharmMiscProject/autorun/logs/repo_clone"
./clone_all_repos.sh
```

## 3. 运行自动修复

### 3.1 预热缓存

这会先执行 `clone_all_repos.sh`，不跑修复：

```bash
cd /Users/jundi/PyCharmMiscProject/autorun
./run_codex_bugfixes.sh --warm-cache
```

### 3.2 运行全部 10 条

```bash
cd /Users/jundi/PyCharmMiscProject/autorun
./run_codex_bugfixes.sh
```

### 3.3 只运行一个实例

```bash
cd /Users/jundi/PyCharmMiscProject/autorun
./run_codex_bugfixes.sh instance_NodeBB__NodeBB-04998908ba6721d64eba79ae3b65a351dcfbc5b5-vnan
```

也可以直接运行样例 JSON 里的第一个实例：

```bash
cd /Users/jundi/PyCharmMiscProject/autorun
./run_first_case_until_pass.sh
```

### 3.4 运行多个实例

```bash
cd /Users/jundi/PyCharmMiscProject/autorun
./run_codex_bugfixes.sh <instance_id_1> <instance_id_2>
```

## 运行时行为

对每个 `instance_id`，脚本会跑两轮：

- `no_skill`
- `with_skill`

每轮会：

1. 从 `repo_cache` 克隆一个新的工作副本
2. checkout 到该 bug 的 `base_commit`
3. 启动一个全新的 `codex exec` session
4. 强制产出 `out/fix.patch`
5. 用 `git apply --check` 验证 patch
6. 如果开启 patch 检查，再调用单补丁评测脚本做基准验证

## 常用环境变量

```bash
export MODEL="gpt-5.4"
export MAX_ATTEMPTS=2
export BASIC_JSON="/Users/jundi/PyCharmMiscProject/autorun/swe_bench_pro_js_ts_basic_10.json"
export REPO_CACHE_DIR="/Users/jundi/PyCharmMiscProject/autorun/repo_cache"
export CLAW_SKILLS_ROOT="/Users/jundi/PycharmProjects/claw-skills"
export SECOND_PASS_SKILL_PATH="/Users/jundi/PycharmProjects/claw-skills/skills/debug-orchestrator-fix/SKILL.md"
```

patch 基准校验相关变量：

```bash
export RUN_PATCH_CHECK=1
export PATCH_CHECK_PYTHON="/Users/jundi/PyCharmMiscProject/SWE-bench_Pro-os/.venv/bin/python"
export PATCH_CHECK_SCRIPT="/Users/jundi/PyCharmMiscProject/SWE-bench_Pro-os/helper_code/run_single_patch_check.py"
export PATCH_CHECK_OUTPUT_ROOT="/tmp/swe-bench-pro-single-patch-eval"
export PATCH_CHECK_REPORT_FILE="/Users/jundi/PyCharmMiscProject/autorun/logs/patch_check_results.md"
```

如果你只想生成 patch、不跑基准 patch 校验：

```bash
export RUN_PATCH_CHECK=0
./run_codex_bugfixes.sh
```

## 输出目录

运行后常见产物：

- `repo_cache/<owner>__<repo>/`
- `runs/<instance_id>/<pass_mode>/attempt-<n>/`
- `logs/<pass_mode>/`
- `patches/no_skill/<instance_id>/fix.patch`
- `patches/with_skill/<instance_id>/fix.patch`
- `logs/patch_check_results.md`

单次 attempt 目录里通常有：

- `input/basic_bug.json`
- `repo/`
- `out/fix.patch`
- `prompt.md`
- `result.json`
- `events.jsonl`

## 最小执行顺序

```bash
cd /Users/jundi/PyCharmMiscProject/autorun

# 1) 准备 basic 数据
# 生成 /Users/jundi/PyCharmMiscProject/autorun/swe_bench_pro_js_ts_basic_10.json

# 2) 预克隆仓库
./clone_all_repos.sh

# 3) 正式运行
./run_codex_bugfixes.sh
```
