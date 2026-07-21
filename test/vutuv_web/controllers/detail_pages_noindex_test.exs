defmodule VutuvWeb.DetailPagesNoIndexTest do
  use VutuvWeb.ConnCase, async: true

  # The per-user profile detail pages (phone numbers, emails, addresses, links,
  # social media, work history, …) expose personal data and must be kept out of
  # search engine indexes and AI corpora. The `:user_pipe` pipeline stamps the
  # page-level `X-Robots-Tag: noindex, noai, noimageai` on every such page
  # (matching their agent-doc siblings), while the public profile page itself
  # stays indexable. robots.txt only asks crawlers not to fetch a URL; this
  # header also guarantees de-indexing when a detail URL is linked from
  # elsewhere.

  @page_level_robots ["noindex, noai, noimageai"]

  setup %{conn: conn} do
    user = insert_activated_user()
    {:ok, conn: conn, user: user}
  end

  describe "X-Robots-Tag on public profile detail pages" do
    test "the phone numbers index is served with the page-level opt-out", %{
      conn: conn,
      user: user
    } do
      conn = get(conn, ~p"/#{user}/phone_numbers")

      assert conn.status == 200
      assert get_resp_header(conn, "x-robots-tag") == @page_level_robots
    end

    test "a detail show page is served with the page-level opt-out", %{conn: conn, user: user} do
      phone = insert(:phone_number, user: user)
      conn = get(conn, ~p"/#{user}/phone_numbers/#{phone}")

      assert conn.status == 200
      assert get_resp_header(conn, "x-robots-tag") == @page_level_robots
    end

    test "every other public detail resource is covered too", %{conn: conn, user: user} do
      for path <- [
            ~p"/#{user}/emails",
            ~p"/#{user}/links",
            ~p"/#{user}/addresses",
            ~p"/#{user}/social_media_accounts",
            ~p"/#{user}/messengers",
            ~p"/#{user}/work_experiences"
          ] do
        result = get(conn, path)

        assert get_resp_header(result, "x-robots-tag") == @page_level_robots,
               "expected the page-level robots header on #{path}"
      end
    end
  end

  describe "the public profile page stays indexable" do
    test "the profile itself is not marked noindex", %{conn: conn, user: user} do
      conn = get(conn, ~p"/#{user}")

      assert conn.status == 200
      assert get_resp_header(conn, "x-robots-tag") == []
    end
  end
end
