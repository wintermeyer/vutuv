defmodule VutuvWeb.PageControllerTest do
  use VutuvWeb.ConnCase, async: true

  describe "GET /robots.txt" do
    test "is served as plain text with a 200" do
      conn = get(build_conn(), "/robots.txt")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/plain"
    end

    test "welcomes crawlers but fences off private and auth areas" do
      body = build_conn() |> get("/robots.txt") |> response(200)

      # Public content stays crawlable.
      assert body =~ "User-agent: *"
      assert body =~ "Allow: /"

      # Sensitive or backstage paths must never be indexed.
      assert body =~ "Disallow: /admin/"
      assert body =~ "Disallow: /sessions"
      assert body =~ "Disallow: /api/"

      # Personal profile detail pages (phone numbers, emails, addresses, …) are
      # off-limits, while the profile page itself stays crawlable.
      assert body =~ "Disallow: /users/*/"
    end
  end

  describe "GET /datenschutzerklaerung" do
    # External target="_blank" links leak window.opener to the destination and
    # can be abused for reverse tabnabbing. Both external references on the
    # privacy page must carry rel="noopener noreferrer".
    test "external target=_blank links carry rel=noopener noreferrer" do
      body = build_conn() |> get(~p"/datenschutzerklaerung") |> html_response(200)

      # Every external link that opens a new tab.
      blank_anchors = Regex.scan(~r/<a[^>]*target="_blank"[^>]*>/, body)

      assert length(blank_anchors) == 2

      for [anchor] <- blank_anchors do
        assert anchor =~ ~s(rel="noopener noreferrer"),
               "expected rel=noopener noreferrer on #{anchor}"
      end
    end
  end

  describe "GET / JSON-LD" do
    # The dead Twitter handle was retired; it must not linger in the static
    # JSON-LD sameAs block on the start page.
    test "does not advertise the retired Twitter handle in sameAs" do
      body = build_conn() |> get(~p"/") |> html_response(200)

      refute body =~ "twitter.com/vutuv"
    end
  end

  describe "POST /new_registration" do
    @valid_attrs %{
      "emails" => %{"0" => %{"value" => "newcomer@example.com"}},
      "first_name" => "Newcomer"
    }

    # The PIN-entry confirmation page shown right after sign-up used to point at
    # the dead @vutuv Twitter account. The whole "Updates about vutuv" line is
    # gone; the PIN form and its instructions must stay untouched.
    test "the PIN confirmation page no longer links to Twitter", %{conn: conn} do
      conn = post(conn, ~p"/new_registration", user: @valid_attrs)
      body = html_response(conn, 200)

      # The confirmation page is the one we are looking at.
      assert body =~ "INBOX"
      # The PIN form is still rendered.
      assert body =~ ~s(name="session[pin]")
      # The Twitter line is gone for good.
      refute body =~ "twitter.com/vutuv"
      refute body =~ "Updates about vutuv are available at"
    end
  end
end
