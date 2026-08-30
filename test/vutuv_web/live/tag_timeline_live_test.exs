defmodule VutuvWeb.TagTimelineLiveTest do
  @moduledoc """
  The tag page's embedded timeline (`VutuvWeb.TagLive.Timeline`): the source
  tabs, the sort, the date range and the search box, all reload-free, plus the
  German render of the labels they carry.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Fediverse.Hashtags
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.PostsHelpers
  alias Vutuv.Tags.Tag

  defp tag_with_post(body, opts \\ []) do
    name = Keyword.get(opts, :name, unique_tag_name("Elixir"))
    author = insert(:activated_user)
    post = PostsHelpers.create_post!(author, %{body: body, tags: name})

    {Repo.get_by!(Tag, name: name), post}
  end

  defp remote_post(tag, text) do
    account =
      Repo.insert!(%RemoteAccount{
        actor_uri: "https://social.example/users/them-#{System.unique_integer([:positive])}",
        host: "social.example",
        handle: "them",
        name: "Them Themself",
        inbox_uri: "https://social.example/inbox"
      })

    now = DateTime.utc_now(:second)

    post =
      Repo.insert!(%RemotePost{
        remote_account_id: account.id,
        object_uri: "https://social.example/posts/#{System.unique_integer([:positive])}",
        origin_url: "https://social.example/@them/1",
        content_text: text,
        audience: "public",
        kind: "note",
        published_at: now,
        received_at: now,
        expires_at: DateTime.add(now, 86_400)
      })

    Hashtags.sync(post, %{"tag" => [%{"type" => "Hashtag", "name" => "#" <> tag.name}]})
    post
  end

  # The timeline is embedded in a dead controller page, so it is driven on its
  # own (`live_isolated`) with the session the template hands it — the same way
  # the post permalink's conversation is tested.
  defp timeline(conn, tag, params \\ %{}) do
    session = Map.merge(%{"tag_id" => tag.id, "locale" => "en"}, params)
    {:ok, view, _html} = live_isolated(conn, VutuvWeb.TagLive.Timeline, session: session)
    view
  end

  # Whether the filter panel is unfolded. Only the bare boolean attribute counts:
  # `data-keep-open` ends in the same four letters and the element's own
  # `[&[open]]:w-full` utility spells them out again, so the word alone would
  # answer "open" on every render.
  defp filters_open?(html) do
    Regex.match?(~r/<details id="tag-timeline-filters"[^>]*\sopen=/, html)
  end

  describe "the filter panel" do
    test "starts folded, so the first post sits right under the tabs", %{conn: conn} do
      {tag, _post} = tag_with_post("Ein Beitrag")

      html = render(timeline(conn, tag))

      # The controls stay in the DOM — a crawler and a reader with no JavaScript
      # get the same page — they are simply not unfolded.
      assert html =~ ~s(id="tag-timeline-filter")
      refute filters_open?(html)
      refute html =~ "data-active-filters"
    end

    test "a shared link that already carries a filter opens it", %{conn: conn} do
      {tag, _post} = tag_with_post("Ein Beitrag über Hamburg")

      html = conn |> timeline(tag, %{"q" => "Hamburg"}) |> render()

      assert filters_open?(html)
    end

    test "the summary counts what is narrowing the list", %{conn: conn} do
      {tag, _post} = tag_with_post("Ein Beitrag über Hamburg")

      view = timeline(conn, tag)
      html = view |> form("#tag-timeline-filter", %{"q" => "Hamburg"}) |> render_change()

      # Search plus a non-default sort is two; the badge is what tells a reader
      # who folded the panel back up that the list below is still narrowed.
      assert html =~ "data-active-filters"
      assert html =~ "1 active"

      html = view |> form("#tag-timeline-filter", %{"sort" => "oldest"}) |> render_change()
      assert html =~ "2 active"
    end
  end

  describe "the merged list" do
    test "shows a vutuv post and a cached fediverse post together", %{conn: conn} do
      {tag, post} = tag_with_post("Ein Beitrag von hier")
      remote_post(tag, "Ein Beitrag von woanders")

      html = render(timeline(conn, tag))

      assert html =~ "Ein Beitrag von hier"
      assert html =~ "Ein Beitrag von woanders"
      assert html =~ "/posts/#{post.id}"
    end

    test "the source tabs narrow it without a reload", %{conn: conn} do
      {tag, _post} = tag_with_post("Ein Beitrag von hier")
      remote_post(tag, "Ein Beitrag von woanders")

      view = timeline(conn, tag)

      vutuv_only = view |> element(~s([data-filter-tab="vutuv"])) |> render_click()
      assert vutuv_only =~ "Ein Beitrag von hier"
      refute vutuv_only =~ "Ein Beitrag von woanders"

      fediverse_only = view |> element(~s([data-filter-tab="fediverse"])) |> render_click()
      assert fediverse_only =~ "Ein Beitrag von woanders"
      refute fediverse_only =~ "Ein Beitrag von hier"
    end

    test "an empty tab keeps the tabs, so there is a way back", %{conn: conn} do
      {tag, _post} = tag_with_post("Nur von hier")

      view = timeline(conn, tag)
      html = view |> element(~s([data-filter-tab="fediverse"])) |> render_click()

      assert html =~ "tag-source-tabs"
      assert has_element?(view, "#tag-timeline-empty")
    end
  end

  describe "sorting" do
    test "the reader can turn the list around", %{conn: conn} do
      {tag, older} = tag_with_post("Der ältere Beitrag")
      author = insert(:activated_user)
      newer = PostsHelpers.create_post!(author, %{body: "Der neuere Beitrag", tags: tag.name})

      view = timeline(conn, tag)

      html = view |> form("#tag-timeline-filter", %{"sort" => "oldest"}) |> render_change()

      # Whichever post's permalink appears first in the markup is the first row.
      assert :binary.match(html, "/posts/#{older.id}") < :binary.match(html, "/posts/#{newer.id}")
    end

    test "sorting by likes ranks a fediverse post by its origin's own tally",
         %{conn: conn} do
      # A vutuv post nobody here liked, and a remote one its own server says was
      # liked forty times (issue #1283). Before those figures existed the remote
      # half counted as zero and was parked at the bottom of this order, under a
      # note apologising for it.
      {tag, local} = tag_with_post("Ein Beitrag von hier")
      remote = remote_post(tag, "Ein Beitrag von woanders")

      Repo.update_all(
        from(p in RemotePost, where: p.id == ^remote.id),
        set: [likes_count: 40]
      )

      view = timeline(conn, tag)
      html = view |> form("#tag-timeline-filter", %{"sort" => "likes"}) |> render_change()

      assert :binary.match(html, "Ein Beitrag von woanders") <
               :binary.match(html, "/posts/#{local.id}")
    end
  end

  describe "search and the date range" do
    test "the search box narrows both sources", %{conn: conn} do
      {tag, _post} = tag_with_post("Etwas über Hamburg")
      author = insert(:activated_user)
      PostsHelpers.create_post!(author, %{body: "Etwas ganz anderes", tags: tag.name})
      remote_post(tag, "Auch etwas über Hamburg")

      view = timeline(conn, tag)
      html = view |> form("#tag-timeline-filter", %{"q" => "Hamburg"}) |> render_change()

      assert html =~ "Etwas über Hamburg"
      assert html =~ "Auch etwas über Hamburg"
      refute html =~ "Etwas ganz anderes"
    end

    test "a date range that excludes everything explains itself", %{conn: conn} do
      {tag, _post} = tag_with_post("Von heute")

      view = timeline(conn, tag)

      html =
        view
        |> form("#tag-timeline-filter", %{"until" => "2020-01-01"})
        |> render_change()

      assert html =~ "tag-timeline-empty"
      assert has_element?(view, "#tag-clear-filters")
    end

    test "clearing the filters brings the list back", %{conn: conn} do
      {tag, _post} = tag_with_post("Von heute")

      view = timeline(conn, tag)
      view |> form("#tag-timeline-filter", %{"q" => "nichtsdergleichen"}) |> render_change()
      assert has_element?(view, "#tag-timeline-empty")

      html = view |> element("#tag-clear-filters") |> render_click()

      assert html =~ "Von heute"
      refute has_element?(view, "#tag-clear-filters")
    end
  end

  describe "a shared link" do
    test "the controller passes its query string into the mount", %{conn: conn} do
      {tag, _post} = tag_with_post("Ein Beitrag von hier")
      remote_post(tag, "Ein Beitrag von woanders")

      # What the page hands the socket for `/tags/<tag>?source=fediverse`.
      html = conn |> timeline(tag, %{"source" => "fediverse"}) |> render()

      assert html =~ "Ein Beitrag von woanders"
      refute html =~ "Ein Beitrag von hier"

      assert conn
             |> get(~p"/tags/#{tag}?source=fediverse")
             |> html_response(200) =~ "Ein Beitrag von woanders"
    end

    test "a nonsense control lands on the full list rather than an error", %{conn: conn} do
      {tag, _post} = tag_with_post("Ein Beitrag von hier")

      html =
        conn
        |> timeline(tag, %{"source" => "nonsense", "sort" => "nonsense", "from" => "heute"})
        |> render()

      assert html =~ "Ein Beitrag von hier"
    end
  end

  describe "the German render" do
    test "labels the controls in German, not in fuzzy-matched nonsense", %{conn: conn} do
      {tag, _post} = tag_with_post("Ein Beitrag")

      html =
        conn
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/tags/#{tag}")
        |> html_response(200)

      assert html =~ "Suche"
      assert html =~ "Sortieren"
      assert html =~ "Neueste zuerst"
      assert html =~ "Älteste zuerst"
      assert html =~ "Meiste Likes"
    end

    test "the folded panel and its badge speak German too", %{conn: conn} do
      {tag, _post} = tag_with_post("Ein Beitrag über Hamburg")

      html =
        conn
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/tags/#{tag}?q=Hamburg")
        |> html_response(200)

      # "Filters" shares a msgid with the newsletter admin's noun label, which
      # is "Filter" — the verb "Filtern" beside a count would read as an order.
      assert html =~ "Filter"
      assert html =~ "1 aktiv"
    end
  end

  describe "reporting a cached post" do
    test "says so in the layout's toast tray, which this LiveView never renders",
         %{conn: conn} do
      {tag, _post} = tag_with_post("Ein Beitrag")
      remote = remote_post(tag, "Etwas aus einem anderen Netz")

      view = timeline(conn, tag, shell_session(insert_activated_user()))

      # Nothing to say yet, so no portal at all.
      refute has_element?(view, "#tag-timeline-flash")

      view
      |> element(~s(button[phx-click="report-remote-post"][phx-value-id="#{remote.id}"]))
      |> render_click()

      # The tray lives in `app.html.heex`, which the controller rendered and this
      # embedded LiveView has no part of, so the confirmation travels by portal.
      # Its contents are a `<template>`, which `element/3` cannot look inside —
      # render the portal itself and read the string.
      portal = view |> element("#tag-timeline-flash") |> render()

      assert portal =~ ~s(data-phx-portal="#toast-tray")
      assert portal =~ "Thank you. Our copy was deleted right away."
    end
  end
end
