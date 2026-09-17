defmodule VutuvWeb.MemberCardController do
  @moduledoc """
  The card behind an `@handle` of our own: a member or an organization page.

  It is the local twin of `VutuvWeb.RemoteActorCardController` and shares its
  panel, its script (`assets/js/mention_card.js`) and its look. A mention in a
  post, a message or a description keeps its `href` to the profile, and a plain
  click by a signed-in member opens this instead: who it is, the viewer's own
  private notes about them (`Vutuv.PersonalNotes`), one Follow button and the
  way onward to the page.

  The anchor names the account as `member:<handle>` or `organization:<handle>`
  (`VutuvWeb.Markdown`). The kind picks the table; the handle is the one the
  anchor's `href` already carries, so the hook adds nothing to what a rendered
  body tells a feed reader or an API client.

  **Every action is a POST or a DELETE**, like the remote card's: a follow must
  never be something a link, a prefetch or a crawler can fire. An account the
  viewer may not see, or one on either side of a block, answers 404, which is
  what tells the script to follow the link after all; the profile then says
  whatever it says about that account.
  """

  use VutuvWeb, :controller

  import VutuvWeb.UserHelpers, only: [same_user?: 2]

  plug(VutuvWeb.Plug.RequireLoginOr404)

  # Both layouts off: a fragment endpoint, see the remote card's note.
  plug(:put_root_layout, html: false)
  plug(:put_layout, html: false)

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias Vutuv.PersonalNotes
  alias Vutuv.Social

  @doc "Who is this, and where do I stand with them."
  def show(conn, %{"account" => ref}), do: with_account(conn, ref, &card(&1, &2))

  @doc """
  Follow the account this card is showing. The follower is always the member
  in the session: a page's managers follow from the page they speak for, which
  is why the card offers no button while the viewer is acting as one.
  """
  def follow(conn, %{"account" => ref}) do
    with_account(conn, ref, fn conn, account ->
      result = if can_follow?(conn, account), do: follow_account(conn, account)
      card(conn, account, match?({:error, _}, result))
    end)
  end

  @doc "Take the follow back. Idempotent: a second tab may have got there first."
  def unfollow(conn, %{"account" => ref}) do
    with_account(conn, ref, fn conn, account ->
      if can_follow?(conn, account), do: unfollow_account(conn, account)
      card(conn, account)
    end)
  end

  defp with_account(conn, ref, fun) do
    viewer = conn.assigns.current_user

    with %{} = account <- resolve(ref),
         true <- PersonalNotes.visible_to?(account, viewer),
         false <- blocked?(viewer, account) do
      fun.(conn, account)
    else
      _ -> conn |> put_status(:not_found) |> text("")
    end
  end

  defp resolve("member:" <> handle), do: Accounts.get_user_by_username(handle)
  defp resolve("organization:" <> handle), do: Organizations.get_organization_by_username(handle)
  defp resolve(_ref), do: nil

  # A block is between two people, so a page has none.
  defp blocked?(viewer, %User{id: id}), do: Social.blocked_between?(viewer.id, id)
  defp blocked?(_viewer, %Organization{}), do: false

  defp follow_account(conn, %User{id: id}), do: Social.follow(conn.assigns.current_user, id)

  defp follow_account(conn, %Organization{} = page),
    do: Social.follow_organization(conn.assigns.current_user, page)

  defp unfollow_account(conn, %User{id: id}) do
    viewer_id = conn.assigns.current_user.id

    if follow_id = Social.follow_id(viewer_id, id), do: Social.unfollow!(viewer_id, follow_id)
  end

  defp unfollow_account(conn, %Organization{} = page),
    do: Social.unfollow_organization(conn.assigns.current_user, page)

  # Nobody follows themselves, and while a member speaks for a page the follow
  # would be ambiguous about who is following; the profile header hides its
  # follow control in that state for the same reason.
  defp can_follow?(conn, account) do
    not same_user?(account, conn.assigns.current_user) and is_nil(conn.assigns[:acting_as])
  end

  defp following?(viewer, %User{id: id}), do: Social.user_follows_user?(viewer.id, id)
  defp following?(viewer, %Organization{} = page), do: Social.follows_organization?(viewer, page)

  defp card(conn, account, error? \\ false) do
    viewer = conn.assigns.current_user
    can_follow? = can_follow?(conn, account)

    render(conn, :card,
      account: account,
      self?: same_user?(account, viewer),
      can_follow?: can_follow?,
      following?: can_follow? and following?(viewer, account),
      notes: PersonalNotes.available?(viewer, account) && PersonalNotes.summary(viewer, account),
      error?: error?
    )
  end
end
