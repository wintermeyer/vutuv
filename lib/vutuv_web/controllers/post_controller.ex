defmodule VutuvWeb.PostController do
  @moduledoc """
  The post permalink (`/:slug/:year/:month/:day/:seq`) and post deletion.

  The permalink is public and crawlable when the post has no denials; any
  denial noindexes the page and hides it from non-matching readers. A denied
  reader gets the follow **teaser** when the only denial is `non_followers`
  (following fixes their access — actionable), and a plain 404 for every
  other audience configuration (revealing *why* access is denied would leak
  the deny list). Unknown and denied are indistinguishable by design.

  Non-canonical counters/dates (`/stefan/2026/6/5/1`) redirect to the padded
  canonical URL.
  """

  use VutuvWeb, :controller

  plug(VutuvWeb.Plug.UserResolveSlug when action in [:show, :index])
  plug(VutuvWeb.Plug.EnsureValidated when action in [:show, :index])
  plug(VutuvWeb.Plug.RequireLogin when action in [:delete])

  alias Vutuv.Posts
  alias Vutuv.Posts.Post

  # The author archive: /:slug/posts, offset-paginated like the other
  # browse pages. Lists only what the viewer may see, so it is as crawlable
  # as the permalinks it links to.
  def index(conn, params) do
    author = conn.assigns[:user]
    {posts, total} = Posts.author_posts_page(author, conn.assigns[:current_user], params)

    render(conn, "index.html",
      author: author,
      posts: posts,
      total: total,
      page_title: "#{VutuvWeb.UserHelpers.full_name(author)} · #{gettext("Posts")}"
    )
  end

  def show(conn, %{"year" => year, "month" => month, "day" => day, "seq" => seq}) do
    author = conn.assigns[:user]
    viewer = conn.assigns[:current_user]

    with {:ok, date} <- parse_date(year, month, day),
         {:ok, seq_int} <- parse_seq(seq),
         %Post{} = post <- Posts.get_post(author, date, seq_int) do
      canonical = Posts.path(post)

      cond do
        conn.request_path != canonical ->
          redirect(conn, to: canonical)

        Posts.visible_to?(post, viewer) ->
          render_post(conn, post, author, viewer)

        teaser?(post) ->
          conn
          |> put_resp_header("x-robots-tag", "noindex")
          |> render("teaser.html",
            author: author,
            page_title: VutuvWeb.UserHelpers.full_name(author)
          )

        true ->
          VutuvWeb.ControllerHelpers.render_error(conn, 404)
      end
    else
      _ -> VutuvWeb.ControllerHelpers.render_error(conn, 404)
    end
  end

  def delete(conn, %{"id" => id}) do
    current_user = conn.assigns[:current_user]
    post = Posts.get_post(id)

    if post && post.user_id == current_user.id do
      {:ok, _} = Posts.delete_post(post)

      conn
      |> put_flash(:info, gettext("Post deleted successfully."))
      |> redirect(to: ~p"/#{current_user}")
    else
      VutuvWeb.ControllerHelpers.render_error(conn, 404)
    end
  end

  defp render_post(conn, post, author, viewer) do
    restricted? = Posts.restricted?(post)

    conn
    |> maybe_noindex(restricted?)
    |> render("show.html",
      post: post,
      author: author,
      owner?: viewer && viewer.id == post.user_id,
      restricted?: restricted?,
      page_title: "#{VutuvWeb.UserHelpers.full_name(author)} · #{Post.slug(post)}"
    )
  end

  # Restricted posts must never surface in search results, even when the
  # crawler somehow holds a permitted session.
  defp maybe_noindex(conn, true), do: put_resp_header(conn, "x-robots-tag", "noindex")
  defp maybe_noindex(conn, false), do: conn

  # The teaser renders only when following would actually grant access:
  # every denial is the non_followers wildcard.
  defp teaser?(%Post{denials: denials}) do
    denials != [] and Enum.all?(denials, &(&1.wildcard == "non_followers"))
  end

  defp parse_date(year, month, day) do
    with {year, ""} when year >= 1000 <- Integer.parse(year),
         {month, ""} <- Integer.parse(month),
         {day, ""} <- Integer.parse(day) do
      Date.new(year, month, day)
    else
      _ -> :error
    end
  end

  defp parse_seq(seq) do
    case Integer.parse(seq) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> :error
    end
  end
end
