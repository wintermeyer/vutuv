defmodule VutuvWeb.UserTagController do
  use VutuvWeb, :controller

  plug(VutuvWeb.Plug.ResolveOwnedSlug,
    parent: :user,
    assoc: :user_tags,
    join: :tag,
    slug_param: "id",
    field: :slug,
    assign: :user_tag
  )

  plug(VutuvWeb.Plug.AuthUser when action not in [:index, :show])
  plug(:scrub_params, "tag_param" when action in [:create])

  alias Vutuv.Tags.UserTag
  alias VutuvWeb.ControllerHelpers

  def index(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload(user_tags: :tag)

    render(conn, "index.html", user: user, user_tags: user.user_tags)
  end

  def new(conn, _params) do
    changeset = UserTag.changeset(%UserTag{})
    render(conn, "new.html", changeset: changeset)
  end

  # Accepts a single tag or several comma-separated ones ("PHP, JavaScript, Go").
  # Inserts go through `Vutuv.Tags.add_user_tag/2` (shared with the sign-up
  # form's tag field). A single tag keeps the inline-error re-render (a
  # duplicate / invalid name shown on the form); a batch redirects with a
  # count of how many were added.
  def create(conn, %{"tag_param" => tag_param}) do
    user = conn.assigns[:current_user]

    case Vutuv.Tags.parse_tag_names(tag_param["value"]) do
      # Nothing usable typed: re-render the form with the error banner. (Never
      # hand a nil/blank value to create_or_link_tag — it would crash on
      # String.downcase/1.)
      [] ->
        changeset = %UserTag{} |> UserTag.changeset(%{}) |> Map.put(:action, :insert)
        render(conn, "new.html", changeset: changeset)

      [single] ->
        create_single(conn, user, single)

      many ->
        results = Enum.map(many, &Vutuv.Tags.add_user_tag(user, &1))
        failures = Enum.count(results, &match?({:error, _}, &1))

        conn
        |> put_flash(:info, tags_added_flash(length(results) - failures, failures))
        |> redirect(to: ~p"/#{conn.assigns[:user]}/tags")
    end
  end

  defp create_single(conn, user, value) do
    ControllerHelpers.save(conn, Vutuv.Tags.add_user_tag(user, value),
      flash: gettext("User tag created successfully."),
      redirect_to: ~p"/#{conn.assigns[:user]}/tags",
      render: "new.html"
    )
  end

  defp tags_added_flash(successes, 0) do
    ngettext("Added %{count} tag.", "Added %{count} tags.", successes, count: successes)
  end

  defp tags_added_flash(successes, failures) do
    gettext(
      "Added %{successes} of %{total} tags (the rest were duplicates or invalid).",
      successes: successes,
      total: successes + failures
    )
  end

  def show(conn, %{"id" => _id}) do
    user_tag =
      conn.assigns[:user_tag]
      |> Repo.preload([:tag, :endorsements])

    render(conn, "show.html", user_tag: user_tag)
  end

  def delete(conn, %{"id" => _id}) do
    user_tag = conn.assigns[:user_tag]

    # Here we use delete! (with a bang) because we expect
    # it to always work (and if it does not, it will raise).
    Repo.delete!(user_tag)

    conn
    |> put_flash(:info, gettext("User tag deleted successfully."))
    |> redirect(to: ~p"/#{conn.assigns[:user]}/tags")
  end
end
