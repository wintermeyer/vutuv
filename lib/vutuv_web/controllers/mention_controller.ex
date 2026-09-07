defmodule VutuvWeb.MentionController do
  @moduledoc """
  The composer's `@`-picker (issue #1748): the two small JSON answers the
  Markdown editor asks for while somebody types a mention.

  `suggest` offers accounts for a half-typed handle, `check` says which of the
  handles already in the body actually exist — the second is what lets the
  editor draw a resolved mention as a chip and leave a made-up one as plain
  text, instead of promising a link the renderer will not write.

  Both are for the **signed-in member's own editor**, so they ride the settings
  pipeline (login required, kept out of search indexes) rather than the public
  API. They answer with what `Vutuv.Mentions` decides, so the picker cannot
  offer an account the save would refuse — and cannot become a second, laxer
  way to enumerate members: the same block, moderation and visibility rules
  that govern the search page apply there.

  Under `/system/` like every other non-profile page: profiles own the URL root,
  so a new root word would permanently burn a handle a member could claim.
  """
  use VutuvWeb, :controller

  alias Vutuv.Accounts.User
  alias Vutuv.Avatar
  alias Vutuv.Identity
  alias Vutuv.Mentions
  alias Vutuv.Organizations.Organization
  alias Vutuv.Organizations.OrganizationImage
  alias VutuvWeb.UI

  def suggest(conn, params) do
    results =
      conn.assigns.current_user
      |> Mentions.suggest(params["q"] || "")
      |> Enum.map(&payload/1)

    json(conn, %{results: results})
  end

  @doc """
  Which of the `handles` (a comma-separated list) a member or page holds.

  The editor asks about the whole body at once and remembers the answer, so a
  handle it has already seen costs nothing while the member keeps typing.
  """
  def check(conn, params) do
    # `checked` is not the request echoed back for politeness: one request may
    # carry more handles than `Mentions.max_check_handles/0` answers about, and
    # a client that read silence as "no such account" would strip the chip off a
    # real one. It reports what was actually looked up, so the editor caches an
    # answer only where there is one.
    {checked, known} =
      (params["handles"] || "")
      |> String.split(",", trim: true)
      |> Mentions.check_handles()

    json(conn, %{known: MapSet.to_list(known), checked: checked})
  end

  # One row of the picker. `avatar` is a URL or null: with no picture the
  # editor draws the same initials tile `<.avatar>` draws everywhere else,
  # which is why the initials travel too rather than being derived in JS from a
  # name whose parts we would have to split there. A row is not a link — the
  # pick inserts text at the caret — so it carries no path.
  defp payload(identity) do
    %{
      kind: to_string(Identity.kind(identity)),
      handle: Identity.handle(identity),
      name: Identity.display_name(identity),
      avatar: avatar_url(identity),
      initials: initials(identity)
    }
  end

  # `url/2` is already "a real URL or nothing" — nil for a member with no
  # picture, for one the AI gate still holds and for one a copyright case froze
  # — which is what the row wants, because the editor draws the initials tile
  # itself rather than a data URI it cannot size.
  defp avatar_url(%User{} = user), do: Avatar.url(user, :thumb)

  defp avatar_url(%Organization{logo: nil}), do: nil

  defp avatar_url(%Organization{logo: logo}),
    do: OrganizationImage.token_url(logo, "feed")

  # Each kind's own monogram, from the component that draws that kind's tile —
  # one letter for a page, two for a member — so a picker row and the tile it
  # stands in for can never start disagreeing.
  defp initials(%Organization{name: name}), do: UI.organization_initial(name)
  defp initials(user), do: UI.name_initials(user)
end
