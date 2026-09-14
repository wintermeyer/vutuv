Run `mise exec -- mix format` on every changed Elixir file before checking
formatting or running final tests, so fixture and component edits use the
project formatter's layout.
Keep `alias` statements alphabetically ordered within each group and reuse them
for nested modules in tests as well as production code; Credo checks both in CI
even when `mix format` passes.
In Elixir `case` clauses, put ordinary helper-function checks in the branch body,
not in a guard; guards accept only the restricted guard-safe function set.
When allowing anonymous access by matching API paths, test named routes that
share a dynamic path shape (such as `accounts/:id`), so protected endpoints do
not accidentally become public.
When adding actions to another post-card variant, render the shared action-bar
components and reuse their icon controls; a new text-button row breaks the
visual and interaction consistency of the feed.

Before using a Phoenix component or context helper, verify its exported name
and imports in this repository; do not assume generated Phoenix defaults exist.
When toggling persisted fields back in a test, reload the fixture before
creating the next changeset; Ecto compares against the struct, not the database.
Keep Elixir write pipelines shallow: extract validation/building and transactional
persistence into helpers instead of nesting conditionals inside transaction callbacks.

When adding a way to send a message, test its saved display in every conversation
surface (feed, thread, and composer), including anonymous and other-user privacy.
