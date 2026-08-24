---
paths:
  - "**/*.ex"
  - "**/*.exs"
---

## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- **An underscore-prefixed variable still binds and still matches — only a bare `_` is a wildcard.** So repeating the *same* `_name` twice in one clause head silently constrains those two positions to be **equal**, and the clause stops matching when they differ. It reads like "I ignore both", and the compiler says nothing (the `_` prefix is exactly what suppresses the unused-variable warning that would otherwise hint at it). This bit the social-account verify controller: `defp verify_result(conn, _account, {:ok, _account})` required the passed-in account to equal the freshly stamped one returned by `verify/2` — they differ by `verified_at`, so every success fell through to a `FunctionClauseError` on the happy path. Use a bare `_` for anything you genuinely ignore, or give the positions distinct names (`_account` / `_updated`); and when a clause head ignores more than one argument, prefer `_` over a named placeholder so the trap cannot form.
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option
- **A `receive` loop whose exit condition depends on elapsed time must bound its `after` clause with a short tick, not with the whole remaining budget.** `receive do ... after deadline - now() -> ... end` only re-tests the condition when a message *arrives*, so the moment the source goes quiet the loop sleeps to the deadline even though its condition came true seconds earlier. This is invisible in tests and obvious in production: the CDP screenshot driver's stop condition is "the page loaded and then stayed quiet for N ms", and a quiet page sends nothing to wake it — so `https://example.com` took the full 20 s page deadline instead of 2 s, while pages that kept chattering (a consent dialog being clicked away) finished promptly and hid the bug. Block for `min(remaining, tick)` and loop, re-evaluating the condition each tick. The tell to watch for: a wait that is fast when there is traffic and pins to exactly its timeout when there is not.

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Test guidelines

- **An async test module must never insert a unique-key value (tag name/slug, email, username/handle, org slug) that another async test file also inserts.** The SQL sandbox wraps each test in one never-committing transaction, so an inserted unique-index key stays exclusively locked until the test ends; two async files minting the same literal (`insert(:tag, slug: "elixir")`, a shared `"tag_list"`, `username: "alice"`) convoy on that lock, and two such keys acquired in opposite orders deadlock — the long-standing intermittent `40P01 deadlock_detected` in `register_user` at the pre-push gate (root-caused and fixed 2026-07-21). `ON CONFLICT` get-or-create does **not** help in tests: nothing commits, so every test really inserts. Use the factory sequences (`insert(:tag)` with no name), `Vutuv.Factory.unique_tag_name/1` bound to a variable, or the per-module `@registration_tags`; a hardcoded literal is acceptable only in a sync (`async: false`) module or when provably no other async file mints the same value.
- **Before flipping an application env in a test, grep for every reader of that key — the blast radius is the whole codebase, not the module under test.** `Application.put_env/3` is global and the SQL sandbox does not roll it back, so for as long as the test holds a flag down, every *other* async test that reads it sees the changed value. The failure surfaces far from its cause and only sometimes: a landing-page test that set `:fediverse_enabled, false` to check the start page hides its Fediverse section turned `Vutuv.Tags.Timeline.remote_posts_query/1` into `where: false` for whoever was running beside it, and `Vutuv.Tags.TimelineTest` reported a fediverse total of 0 instead of 1 in roughly one full-suite run out of five (2026-08-01). Three consequences: (a) the whole *file* must be `async: false` — the flag is held for the module's lifetime, not the test's; (b) put such tests in their own file rather than making a large useful module sync (`landing_configuration_test.exs` beside `landing_page_test.exs`, the same split `landing_experiment_disabled_test.exs` and `ads_disabled_test.exs` already use); (c) say in the moduledoc which key it flips **and who else reads it**, so the next person can tell at a glance whether a new reader has widened the hazard. When a full-suite run fails on a test your branch never touched, suspect this before suspecting the test.
- **Restoring an application env with `put_env(key, Application.get_env(key))` is not a restore — it can poison the key for the rest of the run.** `get_env/2` answers `nil` both for "the key is absent" and for "the key holds nil", so if anything earlier deleted the key (this repo's own convention for such tests is `Application.delete_env/2`), the naive restore writes `nil` back as a *real value*. Every later reader then gets `nil` instead of the function's default: `Vutuv.Fediverse.enabled?/0` is `Application.get_env(:vutuv, :fediverse_enabled, true)`, and once the key holds `nil` it stops returning `true`, so every `and`/`&&` on it raises `BadBooleanError`. That took down **95** unrelated tests in one run (2026-08-01) with stack traces pointing at `Accounts.activate_user/1`, nowhere near the test that caused it. Capture with **`Application.fetch_env/2`** and restore the two cases apart — `{:ok, was}` puts `was` back, `:error` deletes the key:

      defp put_config(key, value) do
        original = Application.fetch_env(:vutuv, key)
        Application.put_env(:vutuv, key, value)

        on_exit(fn ->
          case original do
            {:ok, was} -> Application.put_env(:vutuv, key, was)
            :error -> Application.delete_env(:vutuv, key)
          end
        end)
      end

  A bare `delete_env/2` on exit is only right for a key whose *absent* state equals its configured state (`:fediverse_enabled` defaults to `true` in both) — for anything configured to a real value in `config/config.exs`, like `:data_location`, deleting it leaks "unset" into every later test.
- **A test module that writes to shared state the SQL sandbox does not roll back must be `async: false` — and so must every other module that touches it.** The sandbox only isolates the database; the global `VutuvWeb.Presence` topic, `Vutuv.Accounts.MemberCounter`'s `:atomics` cell, `:persistent_term` and named singletons are process/node state that outlives a test. Marking only the *asserting* modules sync is not enough: they then avoid each other but still interleave with any `async: true` module that writes the same state. This shipped a real intermittent failure — `VutuvWeb.PresenceTest` (async) tracked members online while `DashboardLiveTest` / `ShellLivePresenceTest` (both sync for exactly this reason) asserted the "online now" count and waited on `assert_receive %Broadcast{event: "presence_diff"}`; the stray member inflated the count and their diff satisfied the wait meant for the test's own join, so the LiveView was flushed before it had the change (fixed 2026-07-22). Say **why** in the moduledoc, naming the shared resource, so the next person doesn't flip it back for speed.
- **A test that asserts on the *order* of a multi-row `Repo.all` result must give the query an explicit `order_by`** — without one, Postgres returns rows in arbitrary order, so the test passes for weeks and then flakes on CI with a different plan (exactly how `fediverse_remote_follows_test.exs`'s `[follow, undo]` match turned `main` red on the v7.185.1 post-merge run; fixed in v7.185.2). Order by `id` when creation order is meant: ids are `Vutuv.UUIDv7` with sub-millisecond ordering bits, so id order **is** creation order. Membership assertions (`x in results`) need no order.
- **A test must never assert against a build artifact — CI runs `mix deps.get` + `mix precommit` and nothing else.** No `npm ci`, no `mix assets.setup`, so anything produced by the asset pipeline (a bundle vendored into `priv/`, a digested file under `priv/static/`) simply is not there when the suite runs, and a test that reads it goes red on CI while passing on every developer machine — which reads as a CI problem and is not one. The consent-blocker tests failed exactly this way: they asserted on the 800 KB autoconsent bundle `mix assets.setup` copies in. Point such a test at a **fixture** it writes itself (a stub file in a temp dir, reached through the module's directory-override config key) so it tests *our* composition rather than a third party's contents, and cover the part a fixture cannot — that the build step is wired up at all — by asserting on the alias directly: `assert "vutuv.autoconsent.vendor" in Mix.Project.config()[:aliases][:"assets.setup"]`. To reproduce CI locally before pushing, move the generated files aside and run the full `mix precommit` in that state.
- **`function_exported?/3` answers `false` for every function of a module that is not LOADED, and loading is lazy — so a test that asks it must `Code.ensure_loaded!/1` first.** Whether some earlier test happened to touch the module depends on the seed and on `max_cases`, so the failure is a random one that names *everything* as missing. `email_html_drift_test.exs` checks that each email template compiled into a `VutuvWeb.EmailText` function; without the ensure_loaded it turned `main` red right after v7.226.0 with all 57 templates listed, on a commit whose own PR run was green and which passed on re-run, and its message sent the reader to `mix compile --force` and `__mix_recompile__?/0` — the wrong place entirely. Recognise the signature: genuine drift is **one** new name, so a list naming every single one is this bug. The same caution applies to `Module.defines?/2`-style reflection in tests and to any `apply/3` guarded by `function_exported?` at runtime.
- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

   - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
- **A test asserting a deadline/duration the code computes from its own clock read must bracket it between two reads, never bound it one-sidedly from a single "before" read.** `before = DateTime.utc_now(:second); call(); assert diff(due, before) <= hold` flakes whenever the wall clock crosses a second boundary inside the call (second-truncated reads make that boundary case common; `fediverse_image_hold_test` turned `main` red with `left: 6, right: 5` on a loaded CI runner, 2026-07-30). Capture `after` as well and assert the bracket — `diff(due, before) >= hold` and `diff(due, after) <= hold` — which is deterministic *and* the stronger claim (the wait IS the configured value, not merely at most it).
- **A test that guards an algorithm's complexity measures reductions, never the wall clock.** `mix test` runs twenty cases in parallel, so `:timer.tc` reports the machine rather than the algorithm — the pathological autolink render in `markdown_test.exs` costs 3 ms of work, was measured at 1.16 s, and failed its `< 1s` bound and the pre-push gate on a change that never touched it. Raising the bound buys time and leaves the instrument wrong. Use `Vutuv.WorkCounter.count_reductions/1` (test support; returns `{reductions, result}` like `:timer.tc/1`): reductions are the scheduler's own unit of work, so a loaded laptop and an idle CI box agree, and they track NIF work too — a catastrophic `:re` backtrack charges about 1.25 million. They are charged per **process**, so work handed to a `Task` is invisible, and the count drifts with the OTP version, so leave a bound an order of magnitude of headroom. **Calibrate both sides** rather than guessing: measure the correct implementation *and* the regression it guards, by removing the guard once and watching the test go red, and keep both numbers in the comment beside the bound (the three in the tree read 387_750 against 25_165_094; 65 against a run that never finishes inside the 60 s timeout; 73_181 against ~15_819_000).
- **Build a test's *dates* from `Vutuv.BerlinTime.today()`, never `Date.utc_today()`** (and Berlin clock helpers, not `DateTime.utc_now()`, wherever a calendar day is the thing under test). vutuv stamps the Berlin calendar day, not the UTC day, into `published_on`, an ad's `day`, the age display and the today/yesterday post wording. A test that creates such a record and then builds its expected date or a `{from, to}` period from `Date.utc_today()` diverges from the code for the ~2 hours each night when Berlin is already the next day (≈22:00–24:00 UTC in CEST summer), so it passes all day and then fails deterministically only in that window — a wall-clock flake that reaches CI at the worst time. This exact gap crash-failed `posts_test.exs` author-posts period scoping until v7.55.1.
