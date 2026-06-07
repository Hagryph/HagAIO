# Test/ — headless unit tests

Pure-logic services tested **outside WoW** with a Lua runtime, so framework
regressions are caught before they reach the game.

## Run

From the repo root:

```sh
luajit Test/run.lua      # LuaJIT = Lua 5.1, same as WoW (recommended)
lua Test/run.lua         # any Lua 5.1+ also works
```

Exits non-zero on failure. CI runs it as the `test` job in
`.github/workflows/lint.yml` (alongside depcheck / toccheck).

A local LuaJIT was installed via `winget install DEVCOM.LuaJIT`
(`%LOCALAPPDATA%\Programs\LuaJIT\bin\luajit.exe`).

## How it works

- `support.lua` loads a HagAIO `.lua` file with a fake `ns` namespace (real
  `Core/Class.lua` + `Core/Service.lua`, stubbed managers/logger) and a
  controllable clock + `C_Timer` stub (`advance(dt)` fires due timers).
- `run.lua` is a tiny, dependency-free runner with a busted-compatible surface
  (`describe` / `it` / `assert.are.equal` / `assert.is_true` / `assert.near` …).

## Adding a spec

1. Create `Test/<name>_spec.lua` (start with `local S = dofile("Test/support.lua")`).
2. Add `"<name>"` to the `SPECS` list in `run.lua`.

## Covered

DependencyGraph · Scaling · Cache (LRU/TTL) · Memoize (trie/nil/NaN/multi-return) ·
Scheduler (Every/After/throttle/debounce).
