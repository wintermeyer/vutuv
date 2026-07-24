defmodule VutuvWeb.PostController do
  @moduledoc """
  The author post archive (`/:slug/posts`, optionally scoped to a year,
  month or day), the post permalink (`/:slug/posts/:id`, the post's UUID v7)
  and post deletion.

  The permalink is public and crawlable when the post has no denials; any
  denial noindexes the page and hides it from non-matching readers. A denied
  reader gets an actionable **teaser** when one relationship unlocks the post:
  the follow teaser when the only denial is `non_followers`, the connect teaser
  when it is `non_connections`. Every other audience configuration is a plain
  404 (revealing *why* access is denied would leak the deny list). Unknown and
  denied are indistinguishable by design.

  Non-canonical id casing (`/stefan/posts/0197A3…`) redirects to the
  canonical lowercase URL.
  """

  use VutuvWeb, :controller

  plug(VutuvWeb.Plug.UserResolveSlug when action in [:show, :index])
  plug(VutuvWeb.Plug.EnsureActivated when action in [:show, :index])
  plug(VutuvWeb.Plug.RequireLogin when action in [:delete])

  alias Vutuv.Fediverse
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.SocialFeed.Http
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.PostDoc
  alias VutuvWeb.Fediverse.Docs, as: FediverseDocs
  alias VutuvWeb.FediverseController

  # The author archive: /:slug/posts, optionally scoped to a year, month or
  # day (/:slug/posts/2026[/06[/06]]), offset-paginated like the other
  # browse pages. Lists only what the viewer may see, so it is as crawlable
  # as the permalinks it links to.
  # Also served as Markdown / text / JSON (.md/.txt/.json or Accept
  # negotiation), rendered from VutuvWeb.AgentDocs.PostDoc.build_archive/5 —
  # always the anonymous view. Keep index.html and the doc builder in sync
  # (agent_docs_drift_test.exs).
  def index(conn, params) do
    author = conn.assigns[:user]

    case {parse_period(params), AgentDocs.negotiate(conn)} do
      {{:ok, period, period_label}, :html} ->
        # The type filter (issue #945) applies only on the unscoped archive —
        # a period-scoped page is date browsing, and it keeps the agent-doc
        # siblings (which ignore ?type=) canonical to the plain archive.
        filter = if is_nil(period), do: Posts.normalize_post_filter(params["type"]), else: :all

        {posts, total} =
          Posts.author_posts_page(author, conn.assigns[:current_user], params, period, filter)

        conn
        |> AgentDocs.put_html_alternates()
        |> AgentDocs.put_feed_alternate(
          VutuvWeb.Feeds.user_feed_path(author),
          "#{VutuvWeb.UserHelpers.full_name(author)} · #{gettext("Posts")}"
        )
        |> render("index.html",
          author: author,
          posts: posts,
          total: total,
          post_filter: Atom.to_string(filter),
          period_label: period_label,
          period_crumbs: period_crumbs(author, params, period_label),
          page_title: "#{VutuvWeb.UserHelpers.full_name(author)} · #{gettext("Posts")}"
        )

      {{:ok, period, period_label}, format} ->
        # Agent-format siblings always render the plain archive (no ?type=), so
        # the .md/.txt/.json/.xml stay one canonical document (drift test).
        {posts, total} = Posts.author_posts_page(author, nil, params, period)
        doc = PostDoc.build_archive(author, conn.request_path, posts, total, period_label)
        AgentDocs.send_doc(conn, format, doc)

      {:error, _format} ->
        VutuvWeb.ControllerHelpers.render_error(conn, 404)
    end
  end

  # nil period = the whole archive; otherwise an inclusive {from, to} range
  # plus its display label ("2026", "2026-06", "2026-06-06").
  defp parse_period(%{"year" => year} = params) do
    with {:ok, year} <- parse_int(year, 1000, 9999) do
      period_for(year, params["month"], params["day"])
    end
  end

  defp parse_period(_params), do: {:ok, nil, nil}

  defp period_for(year, nil, _day) do
    {:ok, {Date.new!(year, 1, 1), Date.new!(year, 12, 31)}, Integer.to_string(year)}
  end

  defp period_for(year, month, nil) do
    with {:ok, month} <- parse_int(month, 1, 12) do
      from = Date.new!(year, month, 1)
      {:ok, {from, Date.end_of_month(from)}, Calendar.strftime(from, "%Y-%m")}
    end
  end

  defp period_for(year, month, day) do
    with {:ok, month} <- parse_int(month, 1, 12),
         {:ok, day} <- parse_int(day, 1, 31),
         {:ok, date} <- Date.new(year, month, day) do
      {:ok, {date, date}, Date.to_iso8601(date)}
    else
      _ -> :error
    end
  end

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

  # The single extra segment under /:slug/posts is either a post id (the
  # permalink) or a year (the year archive) — the router cannot tell them
  # apart, so the dispatch on the segment's shape lives here.
  def show(conn, %{"id" => id} = params) do
    case Vutuv.UUIDv7.cast_or_nil(id) do
      nil -> index(conn, params |> Map.delete("id") |> Map.put("year", id))
      uuid -> show_post(conn, uuid)
    end
  end

  # The permalink is also served as Markdown / text / JSON, rendered from
  # VutuvWeb.AgentDocs.PostDoc — strictly the anonymous view, so a post a
  # logged-out visitor cannot see has no agent documents either. Keep
  # show.html and the doc builder in sync (agent_docs_drift_test.exs).
  defp show_post(conn, id) do
    author = conn.assigns[:user]
    viewer = conn.assigns[:current_user]
    format = AgentDocs.negotiate(conn)

    case Posts.get_post(author, id) do
      %Post{} = post ->
        canonical = Posts.path(post)

        cond do
          conn.request_path != canonical ->
            # Keep the format (the plug re-appends the extension in before_send)
            # and the query string (?lang=de) across the canonical redirect.
            redirect(conn, to: canonical <> redirect_query(conn))

          # An ActivityPub Accept gets the Note (remote servers dereference a
          # federated post's id) — public posts of federating members only.
          federated_note_request?(conn, author, post) ->
            send_note(conn, author, post)

          format != :html ->
            send_post_doc(conn, format, author, post)

          Posts.visible_to?(post, viewer) ->
            conn
            |> maybe_put_alternates(post)
            |> render_post(post, author, viewer)

          kind = unlockable_teaser_kind(post) ->
            # The teaser only exists for restricted posts — a page-level
            # restriction, so both axes are declared (like the doc side).
            conn
            |> VutuvWeb.ContentPolicy.put_robots_header(true, true)
            |> render("teaser.html",
              author: author,
              teaser_kind: kind,
              page_title: VutuvWeb.UserHelpers.full_name(author)
            )

          true ->
            VutuvWeb.ControllerHelpers.render_error(conn, 404)
        end

      nil ->
        VutuvWeb.ControllerHelpers.render_error(conn, 404)
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
    {noindex?, noai?} = PostDoc.robots_axes(author, restricted?)

    # The conversation itself is the embedded `VutuvWeb.PostLive.Thread`
    # LiveView (windowed for long threads, expanders load more on the fly);
    # the controller only hands it the post id through the template's
    # live_render session.
    conn
    |> VutuvWeb.ContentPolicy.put_robots_header(noindex?, noai?)
    |> render("show.html",
      post: post,
      author: author,
      owner?: Posts.author?(post, viewer),
      restricted?: restricted?,
      auto_scroll?: not page_capture?(conn),
      # The "Other formats" card links to the post's agent siblings — shown only
      # when the anonymous .md/.txt/.json/.xml would actually resolve (the same
      # gate as maybe_put_alternates/2 advertising them in the head).
      show_formats?: Posts.visible_to?(post, nil),
      formats_base: Posts.path(post),
      locale: conn.assigns[:locale],
      page_title:
        "#{VutuvWeb.UserHelpers.full_name(author)} · #{Date.to_iso8601(post.published_on)}"
    )
  end

  # The link-preview screenshot browser reading this page rather than a person
  # (`Vutuv.PageScreenshot`, which sends vutuv's own user agent). Headless
  # Chromium's `--screenshot` renders the document **from the top**, so the
  # thread's arrival scroll jump moves the compositor away before those tiles
  # are painted and the stored preview is an empty page (issue #1033). The
  # capture gets the same conversation, just no jump.
  defp page_capture?(conn) do
    conn |> get_req_header("user-agent") |> List.first() |> Http.own_agent?()
  end

  defp redirect_query(conn) do
    case conn.query_string do
      empty when empty in [nil, ""] -> ""
      query -> "?" <> query
    end
  end

  # The agent formats render strictly the anonymous view: a post a
  # logged-out visitor cannot see has no agent documents either.
  defp federated_note_request?(conn, author, post) do
    FediverseController.ap_request?(conn) and Fediverse.federated?(author) and
      Posts.visible_to?(post, nil)
  end

  # The ActivityPub rendering of a public post (see Vutuv.Fediverse).
  defp send_note(conn, author, post) do
    post = Repo.preload(post, [:images, :review, reply_ref: [:parent_author]])

    note =
      post
      |> FediverseDocs.note(author)
      |> Map.put("@context", "https://www.w3.org/ns/activitystreams")

    conn
    |> put_resp_content_type("application/activity+json")
    |> send_resp(200, Jason.encode!(note))
  end

  defp send_post_doc(conn, format, author, post) do
    if Posts.visible_to?(post, nil) do
      AgentDocs.send_doc(conn, format, PostDoc.build(author, post))
    else
      VutuvWeb.ControllerHelpers.render_error(conn, 404)
    end
  end

  # Advertise the agent formats only when the anonymous view can actually
  # fetch them — a restricted post's .md link would 404.
  defp maybe_put_alternates(conn, post) do
    if Posts.visible_to?(post, nil) do
      AgentDocs.put_html_alternates(conn)
    else
      conn
    end
  end

  # A moderation-frozen post gets no teaser: following can't unlock it and a
  # tombstone would leak its existence during the case. Only audience-only
  # restrictions reach teaser_kind/1.
  defp unlockable_teaser_kind(%Post{} = post) do
    if Posts.moderation_hidden?(post), do: nil, else: teaser_kind(post)
  end

  # The teaser renders only when a single, actionable relationship unlocks the
  # post: every denial is the same wildcard, and it is one the reader can
  # resolve themselves — `:follow` (all `non_followers`) or `:connect` (all
  # `non_connections`). Any other denial mix stays an opaque 404.
  defp teaser_kind(%Post{denials: []}), do: nil

  defp teaser_kind(%Post{denials: denials}) do
    cond do
      Enum.all?(denials, &(&1.wildcard == "non_followers")) -> :follow
      Enum.all?(denials, &(&1.wildcard == "non_connections")) -> :connect
      true -> nil
    end
  end
end
