defmodule VutuvWeb.ViewAs do
  @moduledoc """
  Owner-only "View as" preview for the profile section pages
  (work_experiences, phone_numbers, addresses, links, social_media_accounts,
  emails, tags). The bare page is the owner's own view; `?view_as=public`
  reloads server-side so the owner can see the page as a logged-out visitor
  would. A non-owner's `?view_as=` is ignored, so the preview is owner-only and
  never leaks private data.

  `assign_preview/1` sets the assigns the section index templates and the shared
  `<.view_as_switcher>` component read:

    * `:can_preview?` - the viewer owns this profile (so the switcher renders)
    * `:preview_as`   - `nil | :public`
    * `:preview?`     - a preview tier is active
    * `:as_owner?`    - owner AND not previewing; gates the Add / Edit / Delete
      chrome so the public preview mode renders the page read-only

  These mirror the profile's own switcher (`VutuvWeb.UserController`), kept here
  so every section page resolves the preview exactly the same way. Most sections
  are fully public, so the Public preview only toggles the owner's chrome there;
  the emails page also drops its private addresses (which are owner-only, see
  `VutuvWeb.UserHelpers.emails_for_preview/3`).
  """

  import Plug.Conn, only: [assign: 3]

  alias Vutuv.Accounts.User

  @doc """
  Resolves the owner-only preview from `conn.params["view_as"]` and assigns the
  four flags above. Reads `conn.assigns.user` (the profile owner) and
  `conn.assigns.current_user` (the viewer).
  """
  def assign_preview(conn) do
    owner? = owner?(conn.assigns[:current_user], conn.assigns[:user])
    preview_as = preview_as(owner?, conn.params)

    conn
    |> assign(:can_preview?, owner?)
    |> assign(:preview_as, preview_as)
    |> assign(:preview?, not is_nil(preview_as))
    |> assign(:as_owner?, owner? and is_nil(preview_as))
  end

  @doc """
  The preview tier from the `view_as` param, honored only for the owner; any
  unknown value (or a non-owner) yields `nil` (the member's own / real view).
  """
  def preview_as(false, _params), do: nil

  def preview_as(true, params) do
    case params["view_as"] do
      "public" -> :public
      _ -> nil
    end
  end

  defp owner?(%User{id: id}, %User{id: id}), do: true
  defp owner?(_current_user, _user), do: false
end
