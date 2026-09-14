Run `mise exec -- mix format` on every changed Elixir file before checking
formatting or running final tests, so fixture and component edits use the
project formatter's layout.
Keep `alias` statements alphabetically ordered within each group; Credo checks
this in CI even when `mix format` passes.
When adding actions to another post-card variant, render the shared action-bar
components and reuse their icon controls; a new text-button row breaks the
visual and interaction consistency of the feed.
