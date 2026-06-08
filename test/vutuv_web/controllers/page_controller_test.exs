defmodule VutuvWeb.PageControllerTest do
  use VutuvWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

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
      assert body =~ "Disallow: /login"
      assert body =~ "Disallow: /sessions"
      assert body =~ "Disallow: /api/"

      # Personal profile detail pages (phone numbers, emails, addresses, …) are
      # off-limits, while the profile page /<slug> itself stays crawlable.
      assert body =~ "Disallow: /*/emails"
      assert body =~ "Disallow: /*/addresses"

      # The legacy /users/... URLs are redirects now; crawlers can skip them.
      assert body =~ "Disallow: /users/"
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

  describe "GET / sign-up opt-in checkboxes" do
    # Both opt-in boxes on the sign-up form are framed positively (you grant a
    # permission by checking) and start checked, so the friendly defaults
    # (public email, search-indexable profile) are visible and on by default.
    # The indexing box is wired to the inverted `noindex?` field: checked means
    # "allow indexing" (noindex? = false), unchecked means "prevent" (true).
    test "are positively framed and checked by default", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)

      # Positive, parallel phrasing; the old negative "Prevent ..." copy is gone.
      assert body =~ "Allow others to view your email address"
      assert body =~ "Allow search engines to index your profile"
      refute body =~ "Prevent search engines from indexing your profile"

      # Both checkboxes render checked.
      assert checkbox_checked?(body, "user[emails][0][public?]")
      assert checkbox_checked?(body, "user[noindex?]")
    end
  end

  describe "POST /new_registration" do
    @valid_attrs %{
      "emails" => %{"0" => %{"value" => "newcomer@example.com"}},
      "first_name" => "Newcomer"
    }

    # Checking the (inverted) indexing box submits "false", which must land as a
    # search-indexable profile.
    test "checking the indexing box stores an indexable profile", %{conn: conn} do
      attrs =
        Map.merge(@valid_attrs, %{
          "emails" => %{"0" => %{"value" => "indexed@example.com"}},
          "noindex?" => "false"
        })

      post(conn, ~p"/new_registration", user: attrs)

      assert user_by_email("indexed@example.com").noindex? == false
    end

    # Unchecking it submits the hidden "true", flipping the profile to
    # not-indexable. This proves the box drives `noindex?` the inverted way.
    test "unchecking the indexing box stores a non-indexable profile", %{conn: conn} do
      attrs =
        Map.merge(@valid_attrs, %{
          "emails" => %{"0" => %{"value" => "hidden@example.com"}},
          "noindex?" => "true"
        })

      post(conn, ~p"/new_registration", user: attrs)

      assert user_by_email("hidden@example.com").noindex? == true
    end

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

    # A brand-new member must not be greeted with the returning-user
    # "Welcome back!" that the plain login flow uses. The confirmation page
    # marks its PIN form with a registration context for this.
    test "the first PIN login after sign-up greets the newcomer", %{conn: conn} do
      conn = post(conn, ~p"/new_registration", user: @valid_attrs)
      body = html_response(conn, 200)
      assert body =~ ~s(name="session[context]")
      pin = sent_pin()

      conn =
        submit_with_csrf(conn, ~p"/login", %{
          "session" => %{"pin" => pin, "context" => "registration"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Welcome to vutuv!"
    end
  end

  # True when the <input type="checkbox" name=name> in `html` is checked,
  # regardless of attribute order.
  defp checkbox_checked?(html, name) do
    regex = ~r/<input(?=[^>]*\btype="checkbox")(?=[^>]*\bname="#{Regex.escape(name)}")[^>]*>/

    case Regex.run(regex, html) do
      [tag] -> tag =~ "checked"
      _ -> false
    end
  end

  defp user_by_email(value) do
    Vutuv.Repo.one(
      from(u in Vutuv.Accounts.User,
        join: e in assoc(u, :emails),
        where: e.value == ^value
      )
    )
  end
end
