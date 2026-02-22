# S.02 - Skills Evaluation

**Epic:** Skills
**Status:** Not Started
**Priority:** P2 (Medium)
**Estimated Effort:** 3 days
**Dependencies:** S.01 (Skills Runtime)
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Build an evaluation harness that measures skill activation reliability, load discipline, task success uplift, and latency impact. Integrate with the existing `agent-tools/TestSuite` benchmark infrastructure to enable automated testing of skills behavior.

## 2. User Story

As a developer, I want to measure how reliably the agent activates the correct skill and whether skills improve task success rates, so that I can validate skills quality and catch regressions.

## 3. Scope

### In Scope

- Skills-specific benchmark scenarios in `agent-tools/TestSuite`
- Metrics: activation accuracy, load discipline, task success uplift, latency impact
- JSON report output (`~/Library/Application Support/Ora/Evals/{timestamp}-skills.json`)
- Integration with existing `AgentBench` CLI
- At least N=20 skill-related test scenarios

### Out of Scope

- Real-time monitoring / dashboards
- Continuous integration pipeline setup
- Skill quality scoring beyond pass/fail
- A/B testing infrastructure

## 4. Architecture Alignment

### Integration with TestSuite

The existing `agent-tools/TestSuite` provides:
- `AgentLoop.swift` — 1:1 clone of Ora's agent loop
- `ToolRegistry.swift` — Mock tool implementations
- `Benchmark.swift` — Benchmark runner and metrics
- `Judge.swift` — Response quality judging
- Benchmark JSON format for test cases

This story extends the TestSuite to:
- Add mock `skills.*` tools
- Add skill-specific benchmark scenarios
- Add skill-specific judgment criteria
- Report skill metrics

### New Components

```
agent-tools/TestSuite/
├── Sources/AgentBench/
│   ├── SkillsMock.swift       # Mock SkillStore for testing
│   └── SkillsJudge.swift      # Skill-specific judging criteria
├── benchmarks/
│   └── skills.json            # Skill evaluation scenarios
└── ...
```

### Concurrency Model

- Benchmarks run sequentially (one test at a time)
- Each test gets a fresh mock skill store
- Results aggregated after all tests complete

### Metrics Collected

| Metric | Description |
|:-------|:------------|
| `activation_accuracy` | % of tests where correct skill was chosen (when one exists) |
| `load_discipline` | % of tests where `skills.load` was called before using skill content |
| `task_success_baseline` | Success rate without skills enabled |
| `task_success_skills` | Success rate with skills enabled |
| `task_success_uplift` | Difference (skills - baseline) |
| `latency_list_ms` | Time to execute `skills.list` |
| `latency_load_ms` | Time to execute `skills.load` |
| `latency_read_ms` | Time to execute `skills.read` (if used) |

## 5. Implementation Plan (Draft)

### 5.1 Files to Create

#### TestSuite Extensions (`agent-tools/TestSuite/Sources/AgentBench/`)

| File | Purpose |
|:-----|:--------|
| `SkillsMock.swift` | Mock `SkillStore` with configurable skills for testing |
| `SkillsJudge.swift` | Judgment criteria for skill activation and load discipline |

#### Benchmarks (`agent-tools/TestSuite/benchmarks/`)

| File | Purpose |
|:-----|:--------|
| `skills.json` | Skill evaluation scenarios (N >= 20) |

### 5.2 Files to Modify

| File | Change |
|:-----|:-------|
| `agent-tools/TestSuite/Sources/AgentBench/ToolRegistry.swift` | Add mock `skills.list`, `skills.load`, `skills.read` tools |
| `agent-tools/TestSuite/Sources/AgentBench/SystemPrompt.swift` | Add available_skills XML block rendering |
| `agent-tools/TestSuite/Sources/AgentBench/Benchmark.swift` | Add skill metrics collection |
| `agent-tools/TestSuite/Sources/AgentBench/AgentBenchCommand.swift` | Add `--compare-config` flag (accepts `skills`); runs suite twice for uplift reporting |
| `agent-tools/TestSuite/README.md` | Document skills evaluation usage |

### 5.3 Tests to Add

| File | Coverage |
|:-----|:---------|
| `agent-tools/TestSuite/Tests/SkillsMockTests.swift` | Mock store behavior |
| `agent-tools/TestSuite/Tests/SkillsJudgeTests.swift` | Judgment logic |

### 5.4 Dependencies/Config

- No new package dependencies
- Uses existing TestSuite infrastructure

## 6. Acceptance Criteria

### Benchmark Scenarios

- [ ] AC-1: At least 20 skill-related test scenarios in `benchmarks/skills.json`
- [ ] AC-2: Scenarios cover: skill activation, no-skill-needed, wrong skill, multi-step with skill
- [ ] AC-3: Each scenario specifies `expectedSkillId` (or null if no skill expected)

### Mock Infrastructure

- [ ] AC-4: `SkillsMock` provides configurable skill metadata and content
- [ ] AC-5: Mock `skills.list`, `skills.load`, `skills.read` tools register in test registry
- [ ] AC-6: System prompt includes mock available_skills XML block during tests

### Metrics Collection

- [ ] AC-7: Benchmark runner tracks skill activation (which skill was loaded, if any)
- [ ] AC-8: Benchmark runner tracks whether `skills.load` preceded skill content usage
- [ ] AC-9: Latency tracked separately for skill operations

### Judgment Criteria

- [ ] AC-10: Test passes if correct skill chosen (or no skill when none expected)
- [ ] AC-11: Test warns if skill content used without calling `skills.load` first
- [ ] AC-12: Task success judged independently of skill choice

### Reporting

- [ ] AC-13: Skills eval outputs JSON report to `~/Library/Application Support/Ora/Evals/`
- [ ] AC-14: Report includes all metrics (activation accuracy, load discipline, uplift, latencies)
- [ ] AC-15: Report includes per-test breakdown and summary

### CLI Integration

- [ ] AC-16: `swift run AgentBench --suite benchmarks/skills.json` runs skill eval
- [ ] AC-17: `swift run AgentBench --suite benchmarks/skills.json --output <path>` writes the skills-specific JSON report
- [ ] AC-18: `swift run AgentBench --suite benchmarks/skills.json --compare-config skills` runs the suite **twice** (skills-enabled vs. skills-disabled, same model, same test cases) and reports uplift metrics; `--compare-config` is a new flag distinct from the existing `--compare`/`--compare-preset` model-comparison flags

**Baseline comparison methodology:** both runs use the same model and same benchmark cases. The only difference is whether `{{available_skills}}` is injected into the system prompt and whether `skills.*` tools are registered. `task_success_baseline` comes from the skills-disabled run; `task_success_skills` from the enabled run.

## 7. Verification Plan

### Automated Tests

- [ ] Unit tests for SkillsMock (metadata, content, errors)
- [ ] Unit tests for SkillsJudge (activation, load discipline logic)
- [ ] Integration test: run skill benchmark suite, verify metrics reported

### Manual Tests

- [ ] Run full skills benchmark suite (`swift run AgentBench --suite benchmarks/skills.json`)
- [ ] Verify report is written to expected location
- [ ] Verify metrics are reasonable (non-zero activation accuracy, etc.)
- [ ] Run comparison: baseline vs skills-enabled, verify uplift calculated

## 8. Performance / Reliability Considerations

### Targets

| Metric | Target |
|:-------|:-------|
| Full skills eval (20 tests) | < 10 minutes |
| Report generation | < 1 second |

### Failure Modes

| Failure | Handling |
|:--------|:---------|
| Test timeout | Mark as failed, continue suite |
| LLM error | Log error, mark test as failed |
| Report write failure | Log error, print to stdout |

## 9. Risks & Mitigations

| Risk | Mitigation |
|:-----|:-----------|
| LLM non-determinism affects metrics | Run each scenario multiple times, report mean/stddev |
| Skill scenarios too narrow | Design diverse scenarios covering edge cases |
| Baseline comparison unfair | Use identical prompts, only difference is skills availability |

## 10. Open Questions

- Should we track skill-specific token usage? (Defer)
- How many runs per scenario for statistical significance? (Start with 3, increase if needed)

---

## Benchmark Scenario Examples

### Scenario: Correct Skill Activation

```json
{
  "id": "skill-activation-meeting",
  "prompt": "I need to schedule a meeting with John next week",
  "skills": ["meeting-scheduler", "daily-briefing"],
  "expectedSkillId": "meeting-scheduler",
  "expected": {
    "skill_loaded": "meeting-scheduler",
    "tools_called": ["calendar.find_slots", "calendar.create_event"]
  }
}
```

### Scenario: No Skill Needed

```json
{
  "id": "no-skill-simple-query",
  "prompt": "What time is it?",
  "skills": ["meeting-scheduler", "daily-briefing"],
  "expectedSkillId": null,
  "expected": {
    "skill_loaded": null,
    "response_contains": ["time"]
  }
}
```

### Scenario: Load Discipline

```json
{
  "id": "load-discipline-check",
  "prompt": "Use the daily briefing skill to summarize my day",
  "skills": ["daily-briefing"],
  "expectedSkillId": "daily-briefing",
  "expected": {
    "skill_load_called": true,
    "skill_load_before_content_use": true
  }
}
```

---

## Report Format

```json
{
  "timestamp": "2025-01-15T14:30:00Z",
  "model": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "summary": {
    "total_tests": 20,
    "passed": 18,
    "failed": 2,
    "activation_accuracy": 0.90,
    "load_discipline": 0.95,
    "task_success_baseline": 0.75,
    "task_success_skills": 0.85,
    "task_success_uplift": 0.10,
    "avg_latency_list_ms": 5,
    "avg_latency_load_ms": 25,
    "avg_latency_read_ms": 15
  },
  "tests": [
    {
      "id": "skill-activation-meeting",
      "status": "pass",
      "skill_expected": "meeting-scheduler",
      "skill_loaded": "meeting-scheduler",
      "load_discipline": true,
      "task_success": true,
      "latencies": {
        "list_ms": 4,
        "load_ms": 22
      }
    }
  ]
}
```

---

## Implementation Summary

(TBD after implementation.)

## Code Review Findings

(TBD by review agent.)

## Completion Status

(TBD after merge.)
