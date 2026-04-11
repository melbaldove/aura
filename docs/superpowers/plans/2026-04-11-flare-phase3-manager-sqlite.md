# Flare Phase 3: Flare Manager + SQLite Persistence

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce the `flare_manager` actor and move session persistence from JSON file to SQLite. The flare manager wraps the existing transport layer, adds flare identity (UUID, label, status), and persists to a `flares` table via the DB actor.

**Architecture:** The flare manager replaces `acp_manager` in the supervision tree. It delegates transport operations (dispatch, kill, send_input, is_alive) to the existing transport module. Session state that was previously in `session_store.gleam` (JSON) moves to SQLite. The brain talks to the flare manager instead of acp_manager.

**Tech Stack:** Gleam, OTP actors, SQLite (via sqlight/db actor)

**Codebase context:**
- Current acp_manager: `src/aura/acp/manager.gleam` (760 lines)
- Session store: `src/aura/acp/session_store.gleam` (JSON file, 133 lines)
- DB schema: `src/aura/db_schema.gleam` (current_version = 2)
- DB actor: `src/aura/db.gleam`
- Supervisor: `src/aura/supervisor.gleam` — starts acp_manager at line 158
- Brain references `acp_subject` throughout

**Strategy:** Rather than rewrite acp_manager from scratch, we:
1. Add the `flares` table to SQLite
2. Add DB messages for flare CRUD
3. Create `flare_manager.gleam` that mirrors acp_manager's interface but uses SQLite + adds flare identity
4. Swap the supervisor to start flare_manager instead of acp_manager
5. Update brain to reference flare_manager
6. Delete session_store.gleam

---

### Task 1: Add flares table to SQLite schema

**Files:**
- Modify: `src/aura/db_schema.gleam`
- Test: `test/aura/db_schema_test.gleam`

- [ ] **Step 1: Write the failing test**

Add to `test/aura/db_schema_test.gleam`:

```gleam
pub fn schema_v3_creates_flares_table_test() {
  let assert Ok(conn) = sqlight.open(":memory:")
  let assert Ok(_) = db_schema.initialize(conn)
  // Verify flares table exists by inserting
  let assert Ok(_) = sqlight.exec("INSERT INTO flares (id, label, status, domain, thread_id, original_prompt, execution, triggers, tools, created_at_ms, updated_at_ms) VALUES ('test-id', 'test', 'active', 'work', 'ch1', 'do stuff', '{}', '[]', '[]', 1000, 1000)", conn)
  let assert Ok(rows) = sqlight.query("SELECT id FROM flares", on: conn, with: [], expecting: decode.at([0], decode.string))
  list.length(rows) |> should.equal(1)
}
```

- [ ] **Step 2: Add flares table to schema initialization**

In `src/aura/db_schema.gleam`:

Change `const current_version = 2` to `const current_version = 3`.

After the FTS triggers, add:

```gleam
  use _ <- result.try(exec(conn, "
    CREATE TABLE IF NOT EXISTS flares (
      id TEXT PRIMARY KEY,
      label TEXT NOT NULL,
      status TEXT NOT NULL,
      domain TEXT NOT NULL,
      thread_id TEXT NOT NULL,
      original_prompt TEXT NOT NULL,
      execution TEXT NOT NULL,
      triggers TEXT NOT NULL,
      tools TEXT NOT NULL,
      workspace TEXT,
      session_id TEXT,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL
    )
  "))
  use _ <- result.try(exec(conn, "CREATE INDEX IF NOT EXISTS idx_flares_status ON flares(status)"))
  use _ <- result.try(exec(conn, "CREATE INDEX IF NOT EXISTS idx_flares_domain ON flares(domain)"))
```

In `migrate_version`, add the v2→v3 migration:

```gleam
      use _ <- result.try(case v < 3 {
        True -> {
          use _ <- result.try(exec(conn, "
            CREATE TABLE IF NOT EXISTS flares (
              id TEXT PRIMARY KEY,
              label TEXT NOT NULL,
              status TEXT NOT NULL,
              domain TEXT NOT NULL,
              thread_id TEXT NOT NULL,
              original_prompt TEXT NOT NULL,
              execution TEXT NOT NULL,
              triggers TEXT NOT NULL,
              tools TEXT NOT NULL,
              workspace TEXT,
              session_id TEXT,
              created_at_ms INTEGER NOT NULL,
              updated_at_ms INTEGER NOT NULL
            )
          "))
          use _ <- result.try(exec(conn, "CREATE INDEX IF NOT EXISTS idx_flares_status ON flares(status)"))
          exec(conn, "CREATE INDEX IF NOT EXISTS idx_flares_domain ON flares(domain)")
        }
        False -> Ok(Nil)
      })
```

- [ ] **Step 3: Run tests, commit**

Run: `gleam test`

```bash
git add src/aura/db_schema.gleam test/aura/db_schema_test.gleam
git commit -m "feat: add flares table to SQLite schema (v3 migration)"
```

---

### Task 2: Add flare CRUD operations to the DB actor

**Files:**
- Modify: `src/aura/db.gleam`
- Test: `test/aura/db_test.gleam`

- [ ] **Step 1: Add DB message types for flare operations**

Add to `DbMessage` in `src/aura/db.gleam`:

```gleam
  UpsertFlare(
    reply_to: process.Subject(Result(Nil, String)),
    id: String,
    label: String,
    status: String,
    domain: String,
    thread_id: String,
    original_prompt: String,
    execution: String,
    triggers: String,
    tools: String,
    workspace: String,
    session_id: String,
    created_at_ms: Int,
    updated_at_ms: Int,
  )
  LoadFlares(
    reply_to: process.Subject(Result(List(StoredFlare), String)),
    exclude_archived: Bool,
  )
  UpdateFlareStatus(
    reply_to: process.Subject(Result(Nil, String)),
    id: String,
    status: String,
    updated_at_ms: Int,
  )
  UpdateFlareSessionId(
    reply_to: process.Subject(Result(Nil, String)),
    id: String,
    session_id: String,
    updated_at_ms: Int,
  )
```

Add the `StoredFlare` type:

```gleam
pub type StoredFlare {
  StoredFlare(
    id: String,
    label: String,
    status: String,
    domain: String,
    thread_id: String,
    original_prompt: String,
    execution: String,
    triggers: String,
    tools: String,
    workspace: String,
    session_id: String,
    created_at_ms: Int,
    updated_at_ms: Int,
  )
}
```

- [ ] **Step 2: Implement the handlers**

Add handler cases in the actor's message handler and implement the SQL operations using INSERT OR REPLACE, SELECT, and UPDATE.

- [ ] **Step 3: Add convenience functions**

```gleam
pub fn upsert_flare(subject, id, label, status, domain, thread_id, prompt, execution, triggers, tools, workspace, session_id, created_at_ms, updated_at_ms) -> Result(Nil, String)

pub fn load_flares(subject, exclude_archived) -> Result(List(StoredFlare), String)

pub fn update_flare_status(subject, id, status, updated_at_ms) -> Result(Nil, String)

pub fn update_flare_session_id(subject, id, session_id, updated_at_ms) -> Result(Nil, String)
```

- [ ] **Step 4: Write tests, run, commit**

```bash
git add src/aura/db.gleam test/aura/db_test.gleam
git commit -m "feat: flare CRUD operations in DB actor"
```

---

### Task 3: Create flare_manager.gleam

The core new actor. Mirrors acp_manager's interface but adds flare identity and uses SQLite.

**Files:**
- Create: `src/aura/acp/flare_manager.gleam`
- Test: `test/aura/acp/flare_manager_test.gleam`

- [ ] **Step 1: Define types**

```gleam
pub type FlareStatus {
  Active
  Parked
  Archived
  Failed(reason: String)
}

pub type FlareRecord {
  FlareRecord(
    id: String,
    label: String,
    status: FlareStatus,
    domain: String,
    thread_id: String,
    original_prompt: String,
    execution_json: String,
    triggers_json: String,
    tools_json: String,
    workspace: Option(String),
    session_id: Option(String),
    session_name: Option(String),
    execution_ref: Option(transport.SessionHandle),
    created_at_ms: Int,
    updated_at_ms: Int,
  )
}
```

- [ ] **Step 2: Define messages**

```gleam
pub type FlareMsg {
  Ignite(reply_to, label, domain, thread_id, prompt, execution_json, triggers_json, tools_json, workspace)
  Archive(reply_to, flare_id)
  UpdateExecution(flare_id, session_name, session_id, execution_ref)
  UpdateStatus(flare_id, status: FlareStatus)
  Get(reply_to, flare_id)
  GetByLabel(reply_to, label)
  GetBySessionName(reply_to, session_name)
  List(reply_to)
  ListByStatus(reply_to, status: FlareStatus)
  // Delegated from acp_manager
  Dispatch(reply_to, task_spec, thread_id)
  Kill(reply_to, session_name)
  SendInput(reply_to, session_name, input)
  ListSessions(reply_to)
  GetSession(reply_to, session_name)
  MonitorEvent(AcpEvent)
  SetBrainCallback(on_brain_event)
}
```

- [ ] **Step 3: Implement the actor**

The actor holds:
- `flares: Dict(String, FlareRecord)` — in-memory roster
- `sessions: Dict(String, ActiveSession)` — active execution state (from acp_manager)
- Transport, monitor model, brain callback, etc.

Key behavior:
- `Ignite` creates a FlareRecord with UUID, persists to SQLite, returns the ID
- `Dispatch` creates an ActiveSession (same as current acp_manager), links it to a flare via session_name
- `MonitorEvent` updates both session state and flare progress
- On `AcpCompleted`, the flare transitions to Archived (or stays Active for follow-ups)
- Recovery loads flares from SQLite on startup

This task is large — the subagent should build it incrementally, testing as it goes.

- [ ] **Step 4: Write tests for pure functions (status conversion, etc.)**

- [ ] **Step 5: Run tests, commit**

```bash
git add src/aura/acp/flare_manager.gleam test/aura/acp/flare_manager_test.gleam
git commit -m "feat: flare_manager actor — roster, persistence, execution lifecycle"
```

---

### Task 4: Wire flare_manager into supervisor and brain

**Files:**
- Modify: `src/aura/supervisor.gleam`
- Modify: `src/aura/brain.gleam`
- Modify: `src/aura/brain_tools.gleam`

- [ ] **Step 1: Supervisor — replace acp_manager with flare_manager**

Change the supervisor to start `flare_manager` instead of `acp_manager`. The flare_manager takes the same transport and monitor_model config.

- [ ] **Step 2: Brain — change acp_subject to flare_subject**

Replace `acp_subject: process.Subject(manager.AcpMessage)` with `flare_subject: process.Subject(flare_manager.FlareMsg)` throughout BrainState and BrainConfig.

- [ ] **Step 3: Brain tools — update flare tool to use flare_manager**

The flare tool's `ignite` action now creates a flare record first, then dispatches.

- [ ] **Step 4: Run tests, commit**

```bash
git add src/aura/supervisor.gleam src/aura/brain.gleam src/aura/brain_tools.gleam
git commit -m "feat: wire flare_manager into supervisor and brain"
```

---

### Task 5: Delete session_store.gleam

**Files:**
- Delete: `src/aura/acp/session_store.gleam`
- Delete: `test/aura/acp/session_store_test.gleam`
- Modify: `src/aura/acp/manager.gleam` — remove session_store imports (if manager is still referenced)

- [ ] **Step 1: Remove session_store and its test**

- [ ] **Step 2: Clean up any remaining references**

- [ ] **Step 3: Run tests, commit**

```bash
git rm src/aura/acp/session_store.gleam test/aura/acp/session_store_test.gleam
git add -A
git commit -m "refactor: remove session_store.gleam — flares use SQLite"
```

---

### Task 6: Deploy and verify

- [ ] **Step 1: Deploy**

Run: `bash scripts/deploy.sh`

- [ ] **Step 2: Verify recovery**

Restart Aura and verify flares load from SQLite on startup.

- [ ] **Step 3: Test flare lifecycle**

Ignite a flare, check status, verify it persists across restart.
