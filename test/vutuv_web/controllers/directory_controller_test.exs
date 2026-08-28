defmodule VutuvWeb.DirectoryControllerTest do
  @moduledoc """
  The public member directory (`/system/members` + `/system/members/:letter`):
  the human-browsable index of **every** listed member, and the crawl-friendly
  sibling of the sitemap.

  The two sets it holds apart are what these tests are mostly about. A member
  who opted out of search engines (`noindex?`) is listed like anybody else —
  a directory that hid them was the odd one out beside the most-followed
  listing, the follower lists and `/search`, none of which ever did — and what
  the opt-out buys is `rel="nofollow"` on their row plus their absence from
  the sitemap. Unconfirmed and moderation-hidden accounts are still nowhere.
  """

  use VutuvWeb.ConnCase, async: true

  setup do
    adler = insert_activated_user(first_name: "Anna", last_name: "Adler")
    ozil = insert_activated_user(first_name: "Mesut", last_name: "Özil")
    opted_out = insert_activated_user(first_name: "Otto", last_name: "Opt-Out", noindex?: true)
    %{adler: adler, ozil: ozil, opted_out: opted_out}
  end

  describe "GET /system/members (index)" do
    test "renders the letter overview with counts", %{conn: conn} do
      conn = get(conn, ~p"/system/members")
      html = html_response(conn, 200)

      assert html =~ "Member directory"
      # letters with members link to their page
      assert html =~ ~p"/system/members/a"
      assert html =~ ~p"/system/members/o"
      # a letter without members renders no link
      refute html =~ ~p"/system/members/x"
    end

    test "counts every listed member, opted out of search engines or not", %{conn: conn} do
      # Otto Opt-Out and Özil both file under O. Before v7.407.0 his noindex?
      # kept the count at 1 and left him off his own letter page.
      html = get(conn, ~p"/system/members") |> html_response(200)

      assert html =~ ~s(data-letter="o" data-count="2")
      assert html =~ ~s(data-letter="a" data-count="1")
      assert html =~ ~s(data-letter="x" data-count="0")
    end

    test "opens with the listed count and nothing else", %{conn: conn, adler: adler} do
      # All three confirmed members. The page used to name the whole membership
      # and the Fediverse head count below that; both are the top bar's
      # business, and three figures above an A-Z strip read as a statistics
      # page (Stefan, 2026-08-13).
      Repo.insert!(%Vutuv.Fediverse.Follower{
        user_id: adler.id,
        actor_uri: "https://remote.example/users/frida",
        inbox_uri: "https://remote.example/users/frida/inbox"
      })

      html = get(conn, ~p"/system/members") |> html_response(200)

      assert html =~ "3 vutuv members, filed alphabetically by last name."
      refute html =~ "open to search engines"
      refute html =~ "members in total"
      refute html =~ "from the Fediverse"
    end

    test "says the same in German", %{conn: conn} do
      # The German render is what real visitors get, and a gettext merge can
      # fuzzy-fill a fresh msgid with an unrelated translation, so the
      # sentence is asserted by name rather than trusted.
      html =
        conn
        |> put_req_header("accept-language", "de-DE,de;q=0.9")
        |> get(~p"/system/members")
        |> html_response(200)

      assert html =~ "3 vutuv Mitglieder, alphabetisch nach Nachname sortiert."
      refute html =~ "Insgesamt gibt es"
    end

    test "the directory page itself is indexable", %{conn: conn} do
      conn = get(conn, ~p"/system/members")

      assert get_resp_header(conn, "x-robots-tag") == []
      refute html_response(conn, 200) =~ ~s(<meta name="robots")
    end
  end

  describe "GET /system/members/:letter" do
    test "lists the members of that letter alphabetically", %{conn: conn} do
      insert_activated_user(first_name: "Zoe", last_name: "Meyer")
      insert_activated_user(first_name: "Anna", last_name: "Meyer")
      insert_activated_user(first_name: "Jonas", last_name: "Maler")

      html = get(conn, ~p"/system/members/m") |> html_response(200)

      assert html =~ "Maler, Jonas"
      jonas = :binary.match(html, "Maler, Jonas") |> elem(0)
      anna = :binary.match(html, "Meyer, Anna") |> elem(0)
      zoe = :binary.match(html, "Meyer, Zoe") |> elem(0)
      assert jonas < anna and anna < zoe
    end

    test "files each row by last name, the way it is sorted", %{conn: conn} do
      # The page is one letter of an alphabet built from last names, so the
      # row leads with the name it is filed under. The avatar's alt text keeps
      # the natural order, which is why this asserts the link text.
      html = get(conn, ~p"/system/members/o") |> html_response(200)

      assert html =~ ">Özil, Mesut</a>"
      refute html =~ ">Mesut Özil</a>"
    end

    test "folds accented names into their base letter", %{conn: conn} do
      html = get(conn, ~p"/system/members/o") |> html_response(200)

      assert html =~ "Özil, Mesut"
    end

    test "lists an opted-out member, and tells crawlers not to follow the link", %{
      conn: conn,
      opted_out: opted_out,
      ozil: ozil
    } do
      html = get(conn, ~p"/system/members/o") |> html_response(200)

      assert html =~ "Opt-Out, Otto"

      # The row is there for people; the two links in it carry rel="nofollow"
      # so a crawler does not walk through to a profile whose owner asked to
      # stay out of search results. A member who allowed indexing gets none.
      assert [_avatar, _name] = nofollow_links(html, opted_out.username)
      assert nofollow_links(html, ozil.username) == []
    end

    test "keeps an opted-out member out of the sitemap", %{opted_out: opted_out, ozil: ozil} do
      # The other half of the pair: listed for people, never advertised to a
      # crawler. If this ever goes green with `listed_users/0` behind the
      # sitemap, the opt-out has quietly stopped meaning anything.
      paths = Vutuv.Sitemap.user_entries(1) |> Enum.map(&elem(&1, 0))

      assert ("/" <> ozil.username) in paths
      refute ("/" <> opted_out.username) in paths
    end

    test "serves the other bucket for names that start with no letter", %{conn: conn} do
      insert_activated_user(first_name: "DJ", last_name: "23skidoo")

      html = get(conn, ~p"/system/members/other") |> html_response(200)

      assert html =~ "23skidoo"
    end

    test "renders an empty state for a letter without members", %{conn: conn} do
      html = get(conn, ~p"/system/members/x") |> html_response(200)

      assert html =~ "No members"
    end

    test "404s on an invalid letter" do
      for bad <- ["aa", "1", "A", "%23"] do
        conn = get(build_conn(), "/system/members/#{bad}")
        assert conn.status == 404
      end
    end

    test "an out-of-range page falls back to page 1", %{conn: conn} do
      html = get(conn, ~p"/system/members/a?page=999") |> html_response(200)

      assert html =~ "Anna Adler"
    end

    test "links the sibling letters for humans and crawlers", %{conn: conn} do
      html = get(conn, ~p"/system/members/a") |> html_response(200)

      assert html =~ ~p"/system/members/o"
    end

    test "paginates at #{Vutuv.Directory.per_page()} members per page", %{conn: conn} do
      # Zero-padded last names make the alphabetical order deterministic:
      # Quast01 .. Quast51, so exactly Quast51 falls onto page 2.
      for i <- 1..(Vutuv.Directory.per_page() + 1) do
        n = String.pad_leading(Integer.to_string(i), 2, "0")
        insert_activated_user(first_name: "Q", last_name: "Quast#{n}")
      end

      page1 = get(conn, ~p"/system/members/q") |> html_response(200)
      assert page1 =~ "Quast01"
      refute page1 =~ "Quast51"
      assert page1 =~ "page=2"

      page2 = get(build_conn(), ~p"/system/members/q?page=2") |> html_response(200)
      assert page2 =~ "Quast51"
      refute page2 =~ "Quast01"
    end
  end

  test "the footer of every page links the directory", %{conn: conn} do
    html = get(conn, ~p"/community") |> html_response(200)

    assert html =~ ~p"/system/members"
  end

  test "the sitemap's static chunk lists the directory" do
    assert "/system/members" in Vutuv.Sitemap.static_paths()
  end

  test "llms.txt documents the directory", %{conn: conn} do
    assert get(conn, "/llms.txt").resp_body =~ "/system/members"
  end
end
