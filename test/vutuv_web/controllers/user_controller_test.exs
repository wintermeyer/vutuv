defmodule VutuvWeb.UserControllerTest do
  use VutuvWeb.ConnCase

  alias Vutuv.Accounts.{Email, User}

  @valid_attrs %{
    "emails" => %{"0" => %{"value" => "email@example.com"}},
    "first_name" => "first_name"
  }
  @update_attrs [first_name: "new_first_name"]
  @invalid_update_attrs [first_name: nil, last_name: nil]
  @invalid_attrs %{
    "emails" => %{"0" => %{"value" => nil}},
    "first_name" => nil,
    "gender" => "male",
    "last_name" => nil
  }

  test "creates resource when valid and redirects", %{conn: conn} do
    conn = post(conn, ~p"/new_registration", user: @valid_attrs)

    assert Repo.one(
             from(u in User,
               join: e in assoc(u, :emails),
               where: e.value == ^@valid_attrs["emails"]["0"]["value"]
             )
           )

    assert html_response(conn, 200) =~ "INBOX"
  end

  test "renders form for new resources", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Sign up"
  end

  test "does not create resource and renders errors when data is invalid", %{conn: conn} do
    conn = post(conn, ~p"/new_registration", user: @invalid_attrs)
    assert html_response(conn, 422) =~ "Sign up"
  end

  test "there is no public user directory (GET /users does not route)", %{conn: conn} do
    # The index action was dead code (its slug plug 404'd it) and its template
    # offered per-row Edit/Delete it could never authorize, so it was removed
    # outright. Admins list users at /admin; everyone else searches. Without
    # the route, /users falls into the root-level slug catch-all and 404s
    # ("users" is a reserved slug nobody can claim).
    {conn, _user} = create_and_login_user(conn)

    assert conn |> get("/users") |> html_response(404)
  end

  test "shows chosen resource", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    conn = get(conn, ~p"/#{user}")
    assert html_response(conn, 200) =~ user.first_name
  end

  test "profile shows how long the account has been a member", %{conn: conn} do
    # Older account: just the year (the join month adds nothing once a profile
    # is a few years old).
    user = insert_activated_user(inserted_at: ~N[2008-02-15 10:00:00])

    html = conn |> get(~p"/#{user}") |> html_response(200)
    assert html =~ "Member since 2008"
    refute html =~ "Member since February 2008"
  end

  test "profile spells out the join month for accounts created this year", %{conn: conn} do
    today = Date.utc_today()
    inserted_at = NaiveDateTime.new!(today.year, today.month, 1, 12, 0, 0)
    user = insert_activated_user(inserted_at: inserted_at)

    html = conn |> get(~p"/#{user}") |> html_response(200)
    month = Calendar.strftime(today, "%B")
    assert html =~ "Member since #{month} #{today.year}"
  end

  test "profile hides a zero follower/following counter", %{conn: conn} do
    # One follower, nobody followed back: the followers counter shows, the
    # following counter is gone (a bare "0 following" says nothing).
    user = insert_activated_user()
    insert(:follow, follower: insert(:user, activated?: true), followee: user)

    html = conn |> get(~p"/#{user}") |> html_response(200)

    assert html =~ ~p"/#{user}/followers"
    refute html =~ ~p"/#{user}/following"
  end

  test "with no followers or following, the counts row is gone and Member since moves up",
       %{conn: conn} do
    user = insert_activated_user(inserted_at: ~N[2008-02-15 10:00:00])

    html = conn |> get(~p"/#{user}") |> html_response(200)

    refute html =~ ~p"/#{user}/followers"
    refute html =~ ~p"/#{user}/following"
    assert html =~ "Member since 2008"
  end

  test "profile uses the content+rail columns from tablet widths up", %{conn: conn} do
    # md (768px), not lg: portrait iPads (768-834px CSS width) should get the
    # desktop column layout too, not the single phone column.
    {conn, user} = create_and_login_user(conn)
    html = conn |> get(~p"/#{user}") |> html_response(200)

    assert html =~ "md:grid-cols-3"
    assert html =~ "md:col-span-2"
  end

  test "the profile header's action buttons wrap on narrow screens", %{conn: conn} do
    # A visitor sees up to three controls (Connect/Follow/Message) beside the
    # avatar; without flex-wrap the last one is clipped off a 390px phone.
    {conn, _visitor} = create_and_login_user(conn)
    profile = insert_activated_user()
    html = conn |> get(~p"/#{profile}") |> html_response(200)

    assert html =~ ~s(id="profile-actions")
    assert [actions_div] = Regex.run(~r/<div id="profile-actions"[^>]*>/, html)
    assert actions_div =~ "flex-wrap"
  end

  test "lists the user's full profile information to visitors", %{conn: conn} do
    user =
      insert_activated_user(
        gender: "female",
        birthdate: ~D[1990-04-15],
        headline: "Hello world"
      )

    insert(:email, user: user, value: "public.contact@example.com")
    insert(:phone_number, user: user, value: "+49 30 5551234")
    insert(:url, user: user, value: "https://example.org/my-site", description: "My Site")
    insert(:address, user: user, city: "Berlin")
    insert(:social_media_account, user: user, provider: "GitHub", value: "octocat")

    follower = insert(:user, activated?: true, first_name: "Fanny")
    insert(:follow, follower: follower, followee: user)
    followee = insert(:user, activated?: true, first_name: "Heidi")
    insert(:follow, follower: user, followee: followee)

    conn = get(conn, ~p"/#{user}")
    html = html_response(conn, 200)

    # Contact, phone numbers, links, addresses, social media
    assert html =~ ~s(id="profile-contact")
    assert html =~ "public.contact@example.com"
    assert html =~ ~s(id="profile-phone-numbers")
    assert html =~ "+49 30 5551234"
    assert html =~ ~s(id="profile-links")
    assert html =~ "https://example.org/my-site"
    assert html =~ ~s(id="profile-addresses")
    assert html =~ "Berlin"
    assert html =~ ~s(id="profile-social-media")
    assert html =~ "octocat"

    # General info (gender, birthday in the en format)
    assert html =~ ~s(id="profile-about")
    assert html =~ "Female"
    assert html =~ "04/15/1990"

    # Follower / following previews
    assert html =~ ~s(id="profile-followers")
    assert html =~ "Fanny"
    assert html =~ ~s(id="profile-following")
    assert html =~ "Heidi"

    # The vCard download now lives in the profile header, not a separate
    # "Exports" rail card, and points at the agent-format URL.
    assert html =~ ~s(id="download-vcard")
    assert html =~ "/#{user.active_slug}.vcf"
    refute html =~ ~s(id="profile-exports")

    # The "Other formats" card links the agent documents (VutuvWeb.AgentDocs).
    assert html =~ ~s(id="profile-other-formats")
    assert html =~ "Other formats"
    assert html =~ "Text only"
    assert html =~ "Markdown"
    assert html =~ "/#{user.active_slug}.md"
    assert html =~ "/#{user.active_slug}.txt"
    assert html =~ "/#{user.active_slug}.json"
  end

  test "renders the headline as Markdown", %{conn: conn} do
    user =
      insert_activated_user(headline: "**Senior** dev, see [my site](https://example.org)")

    html = conn |> get(~p"/#{user}") |> html_response(200)

    # Inline Markdown becomes real markup, not literal asterisks.
    assert html =~ "<strong>Senior</strong>"
    refute html =~ "**Senior**"
    # Links go through VutuvWeb.Markdown, which opens them in a new tab.
    assert html =~ ~s(href="https://example.org")
    assert html =~ ~s(target="_blank")
    assert html =~ ">my site</a>"
  end

  test "hides empty profile sections from visitors", %{conn: conn} do
    user = insert_activated_user()

    conn = get(conn, ~p"/#{user}")
    html = html_response(conn, 200)

    refute html =~ ~s(id="profile-contact")
    refute html =~ ~s(id="profile-phone-numbers")
    refute html =~ ~s(id="profile-links")
    refute html =~ ~s(id="profile-addresses")
    refute html =~ ~s(id="profile-social-media")
    refute html =~ ~s(id="profile-about")
    refute html =~ ~s(id="profile-followers")
    refute html =~ ~s(id="profile-following")
  end

  test "the owner sees the add tile on each still-empty profile section", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    conn = get(conn, ~p"/#{user}")
    html = html_response(conn, 200)

    # A brand-new account's empty sections each carry the dashed add tile into
    # their new-entry form. (Contact already holds the registration email, so it
    # shows the "Manage" footer instead of the tile.)
    for path <- [
          ~p"/#{user}/phone_numbers/new",
          ~p"/#{user}/links/new",
          ~p"/#{user}/social_media_accounts/new",
          ~p"/#{user}/addresses/new",
          ~p"/#{user}/work_experiences/new",
          ~p"/#{user}/tags/new"
        ] do
      assert html =~ path
    end
  end

  test "empty sections invite the owner to add information instead of dead-ending", %{conn: conn} do
    # A brand-new account lands on a profile full of empty cards. Rather than a
    # muted "Nothing here yet." that hides the next step behind the quiet ⋯
    # menu, each empty section shows a clear add prompt the owner can click.
    {conn, user} = create_and_login_user(conn)
    html = conn |> get(~p"/#{user}") |> html_response(200)

    for label <- [
          "Add work experience",
          "Add a link",
          "Add a phone number",
          "Add an address",
          "Add a social media account"
        ] do
      assert html =~ label
    end

    # The dead-end empty-state line is gone from the owner's own view.
    refute html =~ "Nothing here yet."
  end

  test "the add prompts are owner-only and never shown to visitors", %{conn: conn} do
    user = insert_activated_user()
    html = conn |> get(~p"/#{user}") |> html_response(200)

    refute html =~ "Add work experience"
    refute html =~ "Add a link"
    refute html =~ "Add a phone number"
  end

  test "renders page not found when id is nonexistent", %{conn: conn} do
    conn = get(conn, ~p"/#{%User{active_slug: "1"}}")
    assert html_response(conn, :not_found)
  end

  test "renders form for editing chosen resource", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    conn = get(conn, ~p"/#{user}/edit")
    assert html_response(conn, 200) =~ "Edit"
  end

  test "updates chosen resource and redirects when data is valid", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    conn = put(conn, ~p"/#{user}", user: @update_attrs)
    assert redirected_to(conn) == ~p"/#{user}"
    assert Repo.get_by(User, @update_attrs)
  end

  test "a partial update (only the first name) rebuilds search terms instead of wiping them",
       %{conn: conn} do
    # Regression for #780: the web update path used to rebuild search terms from
    # the raw params, so a submission missing the last_name key fell through to
    # create_search_terms(_) -> [] and erased the member from people-search. The
    # fix routes the web path through Accounts.update_user/2, which rebuilds from
    # the changeset's final field values like the API path.
    attrs = %{
      "emails" => %{"0" => %{"value" => "renamed@example.com"}},
      "first_name" => "Jane",
      "last_name" => "Doe"
    }

    {:ok, user} = Vutuv.Accounts.register_user(conn, attrs)
    conn = login_via_pin(conn, "renamed@example.com")
    assert search_term_values(user) != []

    # Submit only the first name (no last_name key, as a partial/non-form post).
    conn = put(conn, ~p"/#{user}", user: %{"first_name" => "Janet"})
    assert redirected_to(conn) == ~p"/#{user}"

    values = search_term_values(user)
    refute values == []
    assert "janet doe" in values
  end

  test "updates the birthdate from the single native date field", %{conn: conn} do
    # The edit form now renders <input type="date">, which submits the date as a
    # single ISO 8601 string rather than the old date_select year/month/day map.
    {conn, user} = create_and_login_user(conn)

    conn = put(conn, ~p"/#{user}", user: %{"birthdate" => "1990-04-15"})
    assert redirected_to(conn) == ~p"/#{user}"
    assert Repo.get(User, user.id).birthdate == ~D[1990-04-15]
  end

  test "the edit form asks the search-engine and the AI question separately", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    html = conn |> get(~p"/#{user}/edit") |> html_response(200)

    assert html =~ "Would you like to allow search engines to index your profile?"
    assert html =~ "Would you like to allow AI agents and LLMs to use your profile?"
  end

  test "account settings are discoverable: a clear, confirmed Delete account control", %{
    conn: conn
  } do
    {conn, user} = create_and_login_user(conn)
    html = conn |> get(~p"/#{user}/edit") |> html_response(200)

    # The data-management cards are clearly labelled (not buried under a vague
    # "Administration" heading), and the GDPR export is still reachable.
    assert html =~ "Delete account"
    assert html =~ "Download your data"

    # The consequence is spelled out before the user acts...
    assert html =~ "cannot be undone"
    # ...and the control is the canonical red danger button with a confirm
    # dialog, replacing the old ad-hoc link styling.
    assert html =~ "button--danger"
    assert html =~ "data-confirm"
    refute html =~ "delete_link_button"
  end

  test "the settings hub links to the otherwise-unfindable privacy/security pages", %{
    conn: conn
  } do
    {conn, user} = create_and_login_user(conn)
    html = conn |> get(~p"/#{user}/edit") |> html_response(200)

    # These pages are reachable only from here for a normal user (no shell or
    # profile link), so the account hub must surface them.
    assert html =~ ~s(href="#{~p"/blocks"}")
    assert html =~ ~s(href="#{~p"/connected_apps"}")
    assert html =~ ~s(href="#{~p"/access_tokens"}")
    assert html =~ ~s(href="#{~p"/moderation/cases"}")
  end

  # The two consents are independent booleans; a mixed combination must
  # land exactly as submitted (the full 2x2 table is unit-tested in
  # robots_txt_test.exs).
  test "updates the search-engine and AI consents independently", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    conn = put(conn, ~p"/#{user}", user: %{"noindex?" => "true", "noai?" => "false"})
    assert redirected_to(conn) == ~p"/#{user}"
    assert %{noindex?: true, noai?: false} = Repo.get(User, user.id)
  end

  # The profile page tells crawlers about the member's choices in a robots
  # meta tag. Two cases prove the layout wiring (no tag without opt-outs;
  # both flags reach ContentPolicy.robots_directives/2, whose full table
  # is unit-tested in robots_txt_test.exs).
  test "the profile page renders the robots meta tag the member chose", %{conn: conn} do
    open = insert_activated_user(noindex?: false, noai?: false)
    refute conn |> get(~p"/#{open}") |> html_response(200) =~ ~s(<meta name="robots")

    private = insert_activated_user(noindex?: true, noai?: true)

    assert build_conn() |> get(~p"/#{private}") |> html_response(200) =~
             ~s(<meta name="robots" content="noindex, noai, noimageai")
  end

  test "profile update ignores email params (emails change only via the PIN flow)", %{conn: conn} do
    # Adding an address goes through EmailController.create, which mails a PIN
    # to the new address and only inserts it after confirmation (issue #759).
    # The profile update must not offer a way around that: neither rewriting an
    # existing address nor smuggling in a new one may stick.
    {conn, user} = create_and_login_user(conn)
    %{emails: [email]} = Repo.preload(user, :emails)

    conn =
      put(conn, ~p"/#{user}",
        user: %{
          "first_name" => "Updated",
          "emails" => %{
            "0" => %{"id" => email.id, "value" => "hijacked@example.com"},
            "1" => %{"value" => "injected@example.com"}
          }
        }
      )

    assert redirected_to(conn) == ~p"/#{user}"
    assert Repo.get(Email, email.id).value == email.value
    refute Repo.get_by(Email, value: "injected@example.com")
  end

  test "edit form has no email inputs, just a link to the email management page", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    conn = get(conn, ~p"/#{user}/edit")
    html = html_response(conn, 200)

    refute html =~ "user[emails]"
    assert html =~ ~p"/#{user}/emails"
  end

  test "the landing-page registration form still asks for the email address", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "user[emails][0][value]"
  end

  test "renders 403 when editing or updating another user's profile", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    other = insert_activated_user()

    assert conn |> get(~p"/#{other}/edit") |> html_response(403)

    assert conn
           |> recycle()
           |> put(~p"/#{other}", user: @update_attrs)
           |> html_response(403)
  end

  test "does not update chosen resource and renders errors when data is invalid", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    conn = put(conn, ~p"/#{user}", user: @invalid_update_attrs)
    assert html_response(conn, 422) =~ "Edit"
  end

  test "deletes chosen resource after confirming the PIN", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    # Step 1: request deletion. Nothing is deleted yet; a PIN is mailed and the
    # confirmation form is shown.
    conn = delete(conn, ~p"/#{user}")
    assert html_response(conn, 200) =~ "PIN"
    assert Repo.get(User, user.id)

    assert_received {:email, email}
    [pin] = Regex.run(~r/\b\d{6}\b/, email.text_body)

    # Step 2: submit the PIN. Now the account is gone.
    conn = post(conn, ~p"/account_deletion", account_deletion: %{pin: pin})
    assert redirected_to(conn) == ~p"/"
    refute Repo.get(User, user.id)
  end

  test "does not delete the account when the PIN is wrong", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    conn = delete(conn, ~p"/#{user}")
    assert_received {:email, _email}

    conn = post(conn, ~p"/account_deletion", account_deletion: %{pin: "000000"})
    assert html_response(conn, 200) =~ "PIN"
    assert Repo.get(User, user.id)
  end

  defp search_term_values(user) do
    user
    |> Ecto.assoc(:search_terms)
    |> Repo.all()
    |> Enum.map(& &1.value)
  end
end
