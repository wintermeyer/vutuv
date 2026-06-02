defmodule VutuvWeb.UserTagEndorsementController do
  use VutuvWeb, :controller

  plug(:resolve_slug)
  plug(:require_user_logged_in)

  alias Vutuv.Tags.UserTagEndorsement
  alias VutuvWeb.ControllerHelpers

  def create(conn, _params) do
    changeset =
      UserTagEndorsement.changeset(
        %UserTagEndorsement{},
        %{user_tag_id: conn.assigns[:user_tag_id], user_id: conn.assigns[:current_user_id]}
      )

    case Repo.insert(changeset) do
      {:ok, _user_tag_endorsement} ->
        conn
        |> put_flash(:info, gettext("Endorsement successful."))
        |> redirect(to: referrer_url(conn))

      {:error, _changeset} ->
        conn
        |> put_flash(:info, gettext("Endorsement unsuccessful."))
        |> redirect(to: referrer_url(conn))
    end
  end

  def delete(conn, _params) do
    Repo.one!(
      from(e in Vutuv.Tags.UserTagEndorsement,
        where:
          e.user_tag_id == ^conn.assigns[:user_tag_id] and
            e.user_id == ^conn.assigns[:current_user_id]
      )
    )
    # Here we use delete! (with a bang) because we expect
    # it to always work (and if it does not, it will raise).
    |> Repo.delete!()

    conn
    |> put_flash(:info, gettext("Unendorsed tag successfully."))
    |> redirect(to: referrer_url(conn))
  end

  defp referrer_url(conn) do
    ControllerHelpers.referrer_url(conn, ~p"/users/#{conn.assigns[:user]}")
  end

  defp resolve_slug(%{params: %{"id" => slug}} = conn, _) do
    Repo.one(
      from(w in assoc(conn.assigns[:user], :user_tags),
        join: t in assoc(w, :tag),
        where: t.slug == ^slug,
        select: w.id
      )
    )
    |> case do
      nil ->
        conn
        |> put_status(404)
        |> put_view(html: VutuvWeb.ErrorHTML)
        |> render("404.html")
        |> halt()

      id ->
        assign(conn, :user_tag_id, id)
    end
  end

  defp resolve_slug(conn, _), do: conn

  defp require_user_logged_in(conn, _) do
    case(conn.assigns[:current_user_id]) do
      nil ->
        conn
        |> put_status(404)
        |> put_view(html: VutuvWeb.ErrorHTML)
        |> render("404.html")
        |> halt()

      _id ->
        conn
    end
  end
end
