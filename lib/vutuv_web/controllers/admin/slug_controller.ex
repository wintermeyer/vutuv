defmodule VutuvWeb.Admin.SlugController do
  use VutuvWeb, :controller

  alias Vutuv.Accounts.Slug

  def index(conn, _params) do
    render(conn, "index.html")
  end

  def update(conn, %{"slug_disable" => %{"value" => value}}) do
    case Repo.one(from(s in Slug, where: s.value == ^value)) do
      nil ->
        conn
        |> put_flash(:error, gettext("Slug doesn't exist."))
        |> render("index.html")

      slug ->
        disable_slug(conn, slug)
    end
  end

  defp disable_slug(conn, slug) do
    changeset = Ecto.Changeset.cast(slug, %{disabled: true}, [:disabled])

    case Repo.update(changeset) do
      {:ok, slug} ->
        update_user_active_slug(conn, slug)

      {:error, _changeset} ->
        redirect(conn, to: ~p"/admin")
    end
  end

  defp update_user_active_slug(conn, slug) do
    user =
      Repo.get(Vutuv.Accounts.User, slug.user_id)
      |> Repo.preload(:slugs)

    user_changeset =
      case Repo.all(
             from(s in Slug,
               where: s.user_id == ^slug.user_id and s.disabled == false,
               select: s.value
             )
           ) do
        [] ->
          slug_value = Vutuv.SlugHelpers.gen_slug_unique(user, Vutuv.Accounts.Slug, :value)

          Ecto.Changeset.cast(user, %{active_slug: slug_value}, [:active_slug])
          |> Ecto.Changeset.put_assoc(:slugs, [
            Slug.changeset(%Slug{}, %{value: slug_value})
          ])

        new ->
          Ecto.Changeset.cast(user, %{active_slug: hd(new)}, [:active_slug])
      end

    case Repo.update(user_changeset) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, gettext("Slug disabled successfully."))
        |> redirect(to: ~p"/admin")

      {:error, _user_changeset} ->
        redirect(conn, to: ~p"/admin")
    end
  end
end
