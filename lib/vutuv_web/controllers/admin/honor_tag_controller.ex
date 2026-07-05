defmodule VutuvWeb.Admin.HonorTagController do
  @moduledoc """
  The admin **Honor tags** overview (`/admin/honor_tags`): the one place to see
  every official badge and who holds it, and to mint a new one in a single step
  (type a name, land on its member roster). Honor tags are otherwise buried in
  the general `/admin/tags` catalog, so an admin could not find or manage them;
  this is the discoverable home for the feature.
  """
  use VutuvWeb, :controller

  alias Vutuv.Tags

  def index(conn, _params) do
    render(conn, "index.html", honor_tags: Tags.honor_tags())
  end

  def create(conn, %{"honor_tag" => %{"name" => name}}) when is_binary(name) do
    case Tags.declare_honor_tag(name) do
      {:ok, tag} ->
        # Straight to the tag's roster so the admin can add members right away.
        conn
        |> put_flash(
          :info,
          gettext("“%{name}” is an honor tag now. Add members below.", name: tag.name)
        )
        |> redirect(to: ~p"/admin/tags/#{tag}")

      {:error, :has_holders, tag} ->
        # Flipping a tag members already hold locks them out of self-removal, so
        # send the admin to the edit form's retroactive-lock warning instead of
        # doing it silently.
        conn
        |> put_flash(
          :error,
          gettext(
            "The tag “%{name}” already exists and members hold it. Review it here before making it an honor tag.",
            name: tag.name
          )
        )
        |> redirect(to: ~p"/admin/tags/#{tag}/edit")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, gettext("Enter a single word with no spaces."))
        |> redirect(to: ~p"/admin/honor_tags")
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, gettext("Enter a single word with no spaces."))
    |> redirect(to: ~p"/admin/honor_tags")
  end
end
