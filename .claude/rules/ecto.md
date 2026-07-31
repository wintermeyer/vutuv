---
paths:
  - "lib/**/*.ex"
  - "priv/repo/**/*.exs"
---

## Ecto Guidelines

- **Always** preload Ecto associations in queries when they'll be accessed in templates, ie a message that needs to reference the `message.user.email`
- Remember `import Ecto.Query` and other supporting modules when you write `seeds.exs`
- `Ecto.Schema` fields always use the `:string` type, even for `:text`, columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such as option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programatically, such as `user_id`, must not be listed in `cast` calls or similar for security purposes. Instead they must be explicitly set when creating the struct
- **Always** invoke `mix ecto.gen.migration migration_name_using_underscores` when generating migration files, so the correct timestamp and conventions are applied. **Generate them one at a time and check the filenames**: two `ecto.gen.migration` calls in the same second produce two files with the *same* timestamp prefix, i.e. the same migration version, which the migrator will not accept. Fold the changes into one migration or regenerate the second a second later.
- **A data migration must be run against `vutuv1_dev` before it ships — a fresh test DB proves nothing about it.** CI and `mix test` create an empty database and migrate it, so every row-touching branch of a backfill is dead code there: the migration "passes" without its insert or update ever executing once. The tag-timeline backfill shipped a `repo().query!` whose placeholders read `($1::uuid, …)`; Postgres reports such a parameter's type as `uuid`, Postgrex then demands the raw **16-byte** form, and `Vutuv.UUIDv7.generate/0`'s readable `019f…` string raised `DBConnection.EncodeError` — on the very first real row, invisible to a green suite. Cast from text instead (**`$1::text::uuid`**, and `$4::timestamp` for a `NaiveDateTime`), which hands Postgres the string it can parse. So: after writing any migration that reads or writes existing rows, run `mise exec -- mix ecto.migrate` on the dev DB and **check the row counts it produced** (`select count(*) from <new table>`), not just that the task exited 0. If dev holds no matching data either, insert a row that matches before migrating.
- **An Ecto `fragment/1` string must not contain a literal `?` — it is the parameter marker**, and Ecto splits the string on it before Postgres ever sees it, so a stray one silently shifts every parameter (or raises about the argument count). This bites hardest with **POSIX regexes**: `substring(? from '^[a-z]+://(?:[^/]+)')` looks fine and is not, because of the `(?:` non-capturing group. Write the pattern without `?` (a plain capturing group and a negated class do the same job: `'^[a-z]+://([^/:#]+)'`), and the same applies to `??`-style JSONB operators — use `jsonb_exists/2` or a helper rather than embedding them. Verify a hand-written fragment against real data in a test, not just by reading it.
