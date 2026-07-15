defmodule Vutuv.Organizations.Query do
  @moduledoc """
  The one SQL spelling of "this organization page is publicly visible" — the
  query twin of `Vutuv.Organizations.public_visible?/1`. The directory, the
  sitemap/indexable set, saved-organization lists, job-posting attribution and
  work-experience linking all build on it, so a changed visibility boundary
  (say a new status) is one edit here plus the struct predicate.

  Note the deliberate non-user: the alias/name collision guardrail counts
  **frozen** pages too (freezing hides a page but keeps `status: "active"`,
  and a moderated page's name stays taken), so it spells its own predicate.
  """

  @doc """
  True when the organization row `o` (a join or the main binding) is on the
  public site: verified `active` and not frozen by moderation. Use inside
  `where:`/`on:` after `import Vutuv.Organizations.Query`. Kept in step with
  the struct predicate `Vutuv.Organizations.public_visible?/1`.
  """
  defmacro organization_public_row(o) do
    quote do
      unquote(o).status == "active" and is_nil(unquote(o).frozen_at)
    end
  end
end
