defmodule VutuvWeb.PostController do
  @moduledoc """
  The author post archive (`/:slug/posts`, optionally scoped to a year,
  month or day), the post permalink (`/:slug/posts/:year/:month/:day/:seq`)
  and post deletion.

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

  # The author archive: /:slug/posts, optionally scoped to a year, month or
  # day (/:slug/posts/2026[/06[/06]]), offset-paginated like the other
  # browse pages. Lists only what the viewer may see, so it is as crawlable
  # as the permalinks it links to.
  def index(conn, params) do
    author = conn.assigns[:user]

    case parse_period(params) do
      {:ok, period, period_label} ->
        {posts, total} =
          Posts.author_posts_page(author, conn.assigns[:current_user], params, period)

        render(conn, "index.html",
          author: author,
          posts: posts,
          total: total,
          period_label: period_label,
          period_crumbs: period_crumbs(author, params, period_label),
          page_title: "#{VutuvWeb.UserHelpers.full_name(author)} · #{gettext("Posts")}"
        )

      :error ->
        VutuvWeb.ControllerHelpers.render_error(conn, 404)
    end
  end

  # nil period = the whole archive; otherwise an inclusive {from, to} range
  # plus its display label ("2026", "2026-06", "2026-06-06").
  defp parse_period(%{"year" => year} = params) do
    with {:ok, year} <- parse_int(year, 1000, 9999) do
      case {params["month"], params["day"]} do
        {nil, _} ->
          {:ok, {Date.new!(year, 1, 1), Date.new!(year, 12, 31)}, Integer.to_string(year)}

        {month, nil} ->
          with {:ok, month} <- parse_int(month, 1, 12) do
            from = Date.new!(year, month, 1)
            {:ok, {from, Date.end_of_month(from)}, Calendar.strftime(from, "%Y-%m")}
          end

        {month, day} ->
          with {:ok, month} <- parse_int(month, 1, 12),
               {:ok, day} <- parse_int(day, 1, 31),
               {:ok, date} <- Date.new(year, month, day) do
            {:ok, {date, date}, Date.to_iso8601(date)}
          else
            _ -> :error
          end
      end
    end
  end

  defp parse_period(_params), do: {:ok, nil, nil}

  defp parse_int(value, min, max) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= min and int <= max -> {:ok, int}
      _ -> :error
    end
  end

  # The trail above a scoped archive — "All posts / 2026 / 06 / 06", every
  # segment but the current one clickable.
  defp period_crumbs(_author, _params, nil), do: []

  defp period_crumbs(author, params, _label) do
    year = params["year"]
    month = params["month"]
    day = params["day"]

    segments =
      [
        {year, ~p"/#{author}/posts/#{year}"},
        month && {month, ~p"/#{author}/posts/#{year}/#{month}"},
        day && {day, ~p"/#{author}/posts/#{year}/#{month}/#{day}"}
      ]
      |> Enum.reject(&is_nil/1)

    # The deepest segment is the page itself — no link.
    {parents, [{current, _href}]} = Enum.split(segments, -1)
    [{gettext("All posts"), ~p"/#{author}/posts"}] ++ parents ++ [{current, nil}]
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

    if post && Posts.author?(post, current_user) do
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
      owner?: Posts.author?(post, viewer),
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
    with {:ok, year} <- parse_int(year, 1000, 9999),
         {:ok, month} <- parse_int(month, 1, 12),
         {:ok, day} <- parse_int(day, 1, 31) do
      Date.new(year, month, day)
    end
  end

  defp parse_seq(seq) do
    case Integer.parse(seq) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> :error
    end
  end
end
