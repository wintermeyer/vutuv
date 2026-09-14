Run `mise exec -- mix format` on every changed Elixir file before checking
formatting or running final tests, so fixture and component edits use the
project formatter's layout.
Keep `alias` statements alphabetically ordered within each group; Credo checks
this in CI even when `mix format` passes.
