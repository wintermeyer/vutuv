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
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Test guidelines

- **An async test module must never insert a unique-key value (tag name/slug, email, username/handle, org slug) that another async test file also inserts.** The SQL sandbox wraps each test in one never-committing transaction, so an inserted unique-index key stays exclusively locked until the test ends; two async files minting the same literal (`insert(:tag, slug: "elixir")`, a shared `"tag_list"`, `username: "alice"`) convoy on that lock, and two such keys acquired in opposite orders deadlock — the long-standing intermittent `40P01 deadlock_detected` in `register_user` at the pre-push gate (root-caused and fixed 2026-07-21). `ON CONFLICT` get-or-create does **not** help in tests: nothing commits, so every test really inserts. Use the factory sequences (`insert(:tag)` with no name), `Vutuv.Factory.unique_tag_name/1` bound to a variable, or the per-module `@registration_tags`; a hardcoded literal is acceptable only in a sync (`async: false`) module or when provably no other async file mints the same value.
- **A test module that writes to shared state the SQL sandbox does not roll back must be `async: false` — and so must every other module that touches it.** The sandbox only isolates the database; the global `VutuvWeb.Presence` topic, `Vutuv.Accounts.MemberCounter`'s `:atomics` cell, `:persistent_term` and named singletons are process/node state that outlives a test. Marking only the *asserting* modules sync is not enough: they then avoid each other but still interleave with any `async: true` module that writes the same state. This shipped a real intermittent failure — `VutuvWeb.PresenceTest` (async) tracked members online while `DashboardLiveTest` / `ShellLivePresenceTest` (both sync for exactly this reason) asserted the "online now" count and waited on `assert_receive %Broadcast{event: "presence_diff"}`; the stray member inflated the count and their diff satisfied the wait meant for the test's own join, so the LiveView was flushed before it had the change (fixed 2026-07-22). Say **why** in the moduledoc, naming the shared resource, so the next person doesn't flip it back for speed.
- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

   - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
- **Build a test's *dates* from `Vutuv.BerlinTime.today()`, never `Date.utc_today()`** (and Berlin clock helpers, not `DateTime.utc_now()`, wherever a calendar day is the thing under test). vutuv stamps the Berlin calendar day, not the UTC day, into `published_on`, an ad's `day`, the age display and the today/yesterday post wording. A test that creates such a record and then builds its expected date or a `{from, to}` period from `Date.utc_today()` diverges from the code for the ~2 hours each night when Berlin is already the next day (≈22:00–24:00 UTC in CEST summer), so it passes all day and then fails deterministically only in that window — a wall-clock flake that reaches CI at the worst time. This exact gap crash-failed `posts_test.exs` author-posts period scoping until v7.55.1.
