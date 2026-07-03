defmodule VutuvWeb.DirectoryControllerTest do
  @moduledoc """
  The public member directory (`/members` + `/members/:letter`): the
  crawl-friendly, human-browsable index of every member who wants to be
  found by search engines. Members who opted out (`noindex?`), are
  unconfirmed or moderation-hidden must never show up here.
  """

  use VutuvWeb.ConnCase, async: true

  setup do
    adler = insert_activated_user(first_name: "Anna", last_name: "Adler")
    ozil = insert_activated_user(first_name: "Mesut", last_name: "Özil")
    opted_out = insert_activated_user(first_name: "Otto", last_name: "Opt-Out", noindex?: true)
    %{adler: adler, ozil: ozil, opted_out: opted_out}
  end

  describe "GET /members (index)" do
    test "renders the letter overview with counts", %{conn: conn} do
      conn = get(conn, ~p"/members")
      html = html_response(conn, 200)

      assert html =~ "Member directory"
      # letters with members link to their page
      assert html =~ ~p"/members/a"
      assert html =~ ~p"/members/o"
      # a letter without members renders no link
      refute html =~ ~p"/members/x"
    end

    test "counts only crawlable members", %{conn: conn} do
      # Otto Opt-Out is the only O-by-last-name besides Özil; his noindex?
      # must keep the O count at 1 (Özil folds into o).
      html = get(conn, ~p"/members") |> html_response(200)

      assert html =~ ~s(data-letter="o" data-count="1")
      assert html =~ ~s(data-letter="a" data-count="1")
      assert html =~ ~s(data-letter="x" data-count="0")
    end

    test "the directory page itself is indexable", %{conn: conn} do
      conn = get(conn, ~p"/members")

      assert get_resp_header(conn, "x-robots-tag") == []
      refute html_response(conn, 200) =~ ~s(<meta name="robots")
    end
  end

  describe "GET /members/:letter" do
    test "lists the members of that letter alphabetically", %{conn: conn} do
      insert_activated_user(first_name: "Zoe", last_name: "Meyer")
      insert_activated_user(first_name: "Anna", last_name: "Meyer")
      insert_activated_user(first_name: "Jonas", last_name: "Maler")

      html = get(conn, ~p"/members/m") |> html_response(200)

      assert html =~ "Jonas Maler"
      jonas = :binary.match(html, "Jonas Maler") |> elem(0)
      anna = :binary.match(html, "Anna Meyer") |> elem(0)
      zoe = :binary.match(html, "Zoe Meyer") |> elem(0)
      assert jonas < anna and anna < zoe
    end

    test "folds accented names into their base letter", %{conn: conn} do
      html = get(conn, ~p"/members/o") |> html_response(200)

      assert html =~ "Mesut Özil"
    end

    test "never lists an opted-out member", %{conn: conn} do
      html = get(conn, ~p"/members/o") |> html_response(200)

      refute html =~ "Otto Opt-Out"
    end

    test "serves the other bucket for names that start with no letter", %{conn: conn} do
      insert_activated_user(first_name: "DJ", last_name: "23skidoo")

      html = get(conn, ~p"/members/other") |> html_response(200)

      assert html =~ "23skidoo"
    end

    test "renders an empty state for a letter without members", %{conn: conn} do
      html = get(conn, ~p"/members/x") |> html_response(200)

      assert html =~ "No members"
    end

    test "404s on an invalid letter" do
      for bad <- ["aa", "1", "A", "%23"] do
        conn = get(build_conn(), "/members/#{bad}")
        assert conn.status == 404
      end
    end

    test "an out-of-range page falls back to page 1", %{conn: conn} do
      html = get(conn, ~p"/members/a?page=999") |> html_response(200)

      assert html =~ "Anna Adler"
    end

    test "links the sibling letters for humans and crawlers", %{conn: conn} do
      html = get(conn, ~p"/members/a") |> html_response(200)

      assert html =~ ~p"/members/o"
    end
  end

  test "the footer of every page links the directory", %{conn: conn} do
    html = get(conn, ~p"/community") |> html_response(200)

    assert html =~ ~p"/members"
  end

  test "the sitemap's static chunk lists the directory" do
    assert "/members" in Vutuv.Sitemap.static_paths()
  end

  test "llms.txt documents the directory", %{conn: conn} do
    assert get(conn, "/llms.txt").resp_body =~ "/members"
  end
end
