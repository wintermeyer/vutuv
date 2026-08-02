defmodule VutuvWeb.PostVerifiedLinkTest do
  @moduledoc """
  A link in a post that points at a webpage the **author** proved is theirs
  wears the verified mark on the real pages (issue #1246) — the permalink and
  every post card a list renders.

  The matching rule itself is `Vutuv.Profiles.VerifiedLinksTest`'s business
  and the rendering `VutuvWeb.MarkdownVerifiedLinksTest`'s; what is checked
  here is the wiring: the author's proven links actually reach the renderer
  (they ride in on `Vutuv.Posts.post_preloads/0`, so a page of cards costs one
  query rather than one per card), only **that** author's proofs count, and a
  proof that lapsed stops marking.
  """
  use VutuvWeb.ConnCase, async: true

  import Vutuv.PostsHelpers

  @proved_at ~N[2026-08-01 10:00:00]

  defp verified_link(user, value, method \\ "rel_me") do
    insert(:url,
      user: user,
      value: value,
      description: "Not the anchor text",
      verification_method: method,
      verified_at: @proved_at
    )
  end

  setup do
    %{author: insert_activated_user(username: "proof_owner", first_name: "Pia")}
  end

  test "the permalink marks a link to the page the author proved", %{conn: conn, author: author} do
    verified_link(author, "https://pia.example/~pia")
    post = create_post!(author, %{"body" => "Fresh: https://pia.example/~pia"})

    html = conn |> get("/proof_owner/posts/#{post.id}") |> html_response(200)

    assert html =~ "verified-author-link"
    assert html =~ "Verified webpage of the author (pia.example/~pia)"
    # The profile entry's own label never replaces the author's anchor text.
    refute html =~ "Not the anchor text"
  end

  test "a post card in a list is marked too, so the preload really travels", %{
    conn: conn,
    author: author
  } do
    verified_link(author, "https://pia.example/~pia")
    create_post!(author, %{"body" => "On my page: https://pia.example/~pia"})

    # The public profile renders the member's posts as cards.
    html = conn |> get("/proof_owner") |> html_response(200)

    assert html =~ "verified-author-link"
  end

  test "a whole page of cards costs one query for the proofs, not one per card", %{
    conn: conn,
    author: author
  } do
    verified_link(author, "https://pia.example/~pia")
    for n <- 1..5, do: create_post!(author, %{"body" => "Nr #{n}: https://pia.example/~pia"})

    {html, url_queries} =
      Vutuv.QueryCounter.count_queries(
        fn -> conn |> get("/proof_owner/posts") |> html_response(200) end,
        matching: ~s(FROM "urls")
      )

    assert length(String.split(html, "verified-author-link")) == 6
    assert url_queries == 1
  end

  test "another member's proof is not borrowed", %{conn: conn, author: author} do
    stranger = insert_activated_user(username: "someone_else")
    verified_link(stranger, "https://pia.example/~pia")

    post = create_post!(author, %{"body" => "Look at https://pia.example/~pia"})
    html = conn |> get("/proof_owner/posts/#{post.id}") |> html_response(200)

    refute html =~ "verified-author-link"
  end

  test "a lapsed verification stops marking", %{conn: conn, author: author} do
    # What Vutuv.Profiles.LinkVerification leaves behind once the grace window
    # runs out: the link is still on the profile, the proof is gone.
    insert(:url,
      user: author,
      value: "https://pia.example/~pia",
      verification_method: nil,
      verified_at: nil
    )

    post = create_post!(author, %{"body" => "Still mine: https://pia.example/~pia"})
    html = conn |> get("/proof_owner/posts/#{post.id}") |> html_response(200)

    refute html =~ "verified-author-link"
  end

  test "a rel=me proof on a shared host does not reach the neighbour", %{
    conn: conn,
    author: author
  } do
    verified_link(author, "https://shared.example/~pia")

    post =
      create_post!(author, %{
        "body" => "Mine: https://shared.example/~pia — Bob's: https://shared.example/~bob"
      })

    html = conn |> get("/proof_owner/posts/#{post.id}") |> html_response(200)

    # Exactly one mark: the proven page, not the neighbour's.
    assert length(String.split(html, "verified-author-link")) == 2
    assert html =~ "Verified webpage of the author (shared.example/~pia)"
  end

  test "a DNS proof reaches every page on the host", %{conn: conn, author: author} do
    verified_link(author, "https://pia.example/", "dns")

    post =
      create_post!(author, %{
        "body" => "Notes: https://pia.example/notes and https://pia.example/talks"
      })

    html = conn |> get("/proof_owner/posts/#{post.id}") |> html_response(200)

    assert length(String.split(html, "verified-author-link")) == 3
    # A host claim names the host — never more than was proved, never less.
    assert html =~ "Verified webpage of the author (pia.example)"
  end

  test "a German visitor reads the mark in German", %{conn: conn, author: author} do
    verified_link(author, "https://pia.example/~pia")
    post = create_post!(author, %{"body" => "Frisch: https://pia.example/~pia"})

    html =
      conn
      |> put_req_header("accept-language", "de-DE,de")
      |> get("/proof_owner/posts/#{post.id}")
      |> html_response(200)

    assert html =~ "Verifizierte Webseite der Autorin oder des Autors (pia.example/~pia)"
  end
end
