Run `mise exec -- mix format` on every changed Elixir file before checking
formatting or running final tests, so fixture and component edits use the
project formatter's layout.
Keep `alias` statements alphabetically ordered within each group; Credo checks
this in CI even when `mix format` passes.
In Elixir `case` clauses, put ordinary helper-function checks in the branch body,
not in a guard; guards accept only the restricted guard-safe function set.
When allowing anonymous access by matching API paths, test named routes that
share a dynamic path shape (such as `accounts/:id`), so protected endpoints do
not accidentally become public.
When adding actions to another post-card variant, render the shared action-bar
components and reuse their icon controls; a new text-button row breaks the
visual and interaction consistency of the feed.
