defmodule VutuvWeb.Admin.TagMemberController do
  @moduledoc """
  The admin roster behind an **honor** tag: add a member to it (by
  `@handle` or email) or remove one, from the tag's `/admin/tags/:slug` page.
  Assignment goes through `Vutuv.Tags.admin_assign_tag/2`, which bypasses the
  member-side reservation deliberately — this route is admin-gated by the
  `:admin` pipeline.
  """
  use VutuvWeb, :controller

  plug(VutuvWeb.Plug.ResolveSlug,
    slug: "tag_slug",
    model: Vutuv.Tags.Tag,
    assign: :tag,
    field: :slug
  )

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Tags
  alias VutuvWeb.ControllerHelpers

  def create(conn, %{"member" => identifier}) when is_binary(identifier) do
    tag = conn.assigns[:tag]

    case identifier |> String.trim() |> Accounts.get_user_by_handle_or_email() do
      %User{} = user ->
        {kind, message} = assigned_flash(Tags.admin_assign_tag(tag, user), user)

        conn |> put_flash(kind, message) |> redirect(to: ~p"/admin/tags/#{tag}")

      nil ->
        conn
        |> put_flash(
          :error,
          gettext("No member found for “%{identifier}”.", identifier: identifier)
        )
        |> redirect(to: ~p"/admin/tags/#{tag}")
    end
  end

  def delete(conn, %{"id" => user_id}) do
    tag = conn.assigns[:tag]

    case ControllerHelpers.get_user(user_id) do
      %User{} = user ->
        Tags.admin_unassign_tag(tag, user)

        conn
        |> put_flash(:info, gettext("Removed @%{handle} from this tag.", handle: user.username))
        |> redirect(to: ~p"/admin/tags/#{tag}")

      nil ->
        conn
        |> put_flash(:error, gettext("Member not found."))
        |> redirect(to: ~p"/admin/tags/#{tag}")
    end
  end

  # A re-assign is a harmless no-op (the member already holds the tag), so it is
  # reported as info, not an error.
  defp assigned_flash({:ok, _user_tag}, user),
    do: {:info, gettext("Gave this tag to @%{handle}.", handle: user.username)}

  defp assigned_flash({:error, _changeset}, user),
    do: {:info, gettext("@%{handle} already has this tag.", handle: user.username)}
end
