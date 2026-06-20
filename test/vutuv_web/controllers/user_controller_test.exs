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
    insert(:follow, follower: insert(:user, email_confirmed?: true), followee: user)

    html = conn |> get(~p"/#{user}") |> html_response(200)

    assert html =~ ~p"/#{user}/followers"
    refute html =~ ~p"/#{user}/following"
  end

  test "with no followers or following, the counts row is gone but Member since still shows",
       %{conn: conn} do
    # "Member since" always anchors the footer row (left of the vCard action),
    # whether or not there is a counts row above it.
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

    follower = insert(:user, email_confirmed?: true, first_name: "Fanny")
    insert(:follow, follower: follower, followee: user)
    followee = insert(:user, email_confirmed?: true, first_name: "Heidi")
    insert(:follow, follower: user, followee: followee)

    conn = get(conn, ~p"/#{user}")
    html = html_response(conn, 200)

    # Contact (e-mails + phone numbers merged into one card), links,
    # addresses, social media.
    assert html =~ ~s(id="profile-contact")
    assert html =~ "public.contact@example.com"
    refute html =~ ~s(id="profile-phone-numbers")
    assert html =~ "+49 30 5551234"
    assert html =~ ~s(id="profile-links")
    assert html =~ "https://example.org/my-site"
    assert html =~ ~s(id="profile-addresses")
    assert html =~ "Berlin"
    assert html =~ ~s(id="profile-social-media")
    assert html =~ "octocat"

    # General info (gender, birthday in the en format, and the derived age)
    assert html =~ ~s(id="profile-about")
    assert html =~ "Female"
    assert html =~ "04/15/1990"
    assert html =~ "#{VutuvWeb.UserHelpers.age(user)} years old"

    # Follower / following previews
    assert html =~ ~s(id="profile-followers")
    assert html =~ "Fanny"
    assert html =~ ~s(id="profile-following")
    assert html =~ "Heidi"

    # The vCard download now lives in the profile header, not a separate
    # "Exports" rail card, and points at the agent-format URL.
    assert html =~ ~s(id="download-vcard")
    assert html =~ "/#{user.username}.vcf"
    refute html =~ ~s(id="profile-exports")

    # The "Other formats" card links the agent documents (VutuvWeb.AgentDocs).
    assert html =~ ~s(id="profile-other-formats")
    assert html =~ "Other formats"
    assert html =~ "Text only"
    assert html =~ "Markdown"
    assert html =~ "/#{user.username}.md"
    assert html =~ "/#{user.username}.txt"
    assert html =~ "/#{user.username}.json"
  end

  # Byte offset of the first occurrence of `needle` in `html`, used to assert the
  # top-to-bottom order of the rail cards by where they appear in the markup.
  defp source_pos(html, needle) do
    case :binary.match(html, needle) do
      {start, _} -> start
      :nomatch -> flunk("expected to find #{inspect(needle)} in the page")
    end
  end

  test "merges e-mail and phone into one Contact card, ordered about-first", %{conn: conn} do
    user = insert_activated_user(gender: "female", birthdate: ~D[1990-04-15])
    insert(:email, user: user, value: "public.contact@example.com")
    insert(:phone_number, user: user, value: "+49 30 5551234")
    insert(:social_media_account, user: user, provider: "GitHub", value: "octocat")
    insert(:address, user: user, city: "Berlin")

    html = conn |> get(~p"/#{user}") |> html_response(200)

    # Phone numbers no longer get their own card: e-mail and phone share the one
    # "Contact" card, so the phone number renders between the Contact card and
    # the next rail card (Social Media), i.e. inside Contact and after the
    # e-mail rows.
    refute html =~ ~s(id="profile-phone-numbers")
    assert source_pos(html, "profile-contact") < source_pos(html, "public.contact@example.com")
    assert source_pos(html, "public.contact@example.com") < source_pos(html, "+49 30 5551234")
    assert source_pos(html, "+49 30 5551234") < source_pos(html, "profile-social-media")

    # About-first rail order: General Info, then Contact, then Social Media,
    # then Addresses.
    assert source_pos(html, "profile-about") < source_pos(html, "profile-contact")
    assert source_pos(html, "profile-contact") < source_pos(html, "profile-social-media")
    assert source_pos(html, "profile-social-media") < source_pos(html, "profile-addresses")
  end

  describe "contact card splits into Beruflich/Privat" do
    # E-mails are work unless typed "Personal"; phone numbers are private only
    # when typed "Home". When both buckets hold something the card grows two
    # labeled groups (work first); a single bucket stays one bare list.

    test "shows a work and a private group when both kinds are present", %{conn: conn} do
      user = insert_activated_user()
      insert(:email, user: user, value: "work.addr@example.com", email_type: "Work")
      insert(:email, user: user, value: "private.addr@example.com", email_type: "Personal")
      insert(:phone_number, user: user, value: "+49 30 5551234", number_type: "Home")

      html = conn |> get(~p"/#{user}") |> html_response(200)

      assert html =~ ~s(data-contact-group="work")
      assert html =~ ~s(data-contact-group="private")
      assert html =~ "Professional"

      # The work address sits in the work group, ahead of the private group; the
      # Personal address and the Home phone land after the private heading.
      assert source_pos(html, ~s(data-contact-group="work")) <
               source_pos(html, "work.addr@example.com")

      assert source_pos(html, "work.addr@example.com") <
               source_pos(html, ~s(data-contact-group="private"))

      assert source_pos(html, ~s(data-contact-group="private")) <
               source_pos(html, "private.addr@example.com")

      assert source_pos(html, ~s(data-contact-group="private")) <
               source_pos(html, "+49 30 5551234")
    end

    test "stays one ungrouped list when every channel is work", %{conn: conn} do
      user = insert_activated_user()
      insert(:email, user: user, value: "only.work@example.com", email_type: "Work")
      insert(:phone_number, user: user, value: "+49 30 5551234", number_type: "Cell")

      html = conn |> get(~p"/#{user}") |> html_response(200)

      assert html =~ "only.work@example.com"
      refute html =~ ~s(data-contact-group="work")
      refute html =~ ~s(data-contact-group="private")
    end
  end

  describe "section card titles pluralize with the entry count" do
    # Each profile section card titles itself after a count: a card with a
    # single entry must read "Phone Number", not "Phone Numbers". The titles go
    # through `ngettext/3`, so the singular/plural split is the i18n library's,
    # not a hand-rolled `if`.

    # The text of the first <h2> (the section title) inside the card with the
    # given DOM id. The section title is always the first heading in a card.
    defp card_title(html, id) do
      [_, rest] = String.split(html, ~s(id="#{id}"), parts: 2)
      [head, _] = String.split(rest, "</h2>", parts: 2)
      head |> String.split(">") |> List.last() |> String.trim()
    end

    test "read singular when a section holds exactly one entry", %{conn: conn} do
      user = insert_activated_user()
      insert(:phone_number, user: user, value: "+49 30 5551234")
      insert(:address, user: user, city: "Berlin")
      insert(:url, user: user, value: "https://example.org/", description: "My Site")
      {:ok, _} = Vutuv.Posts.create_post(user, %{body: "only post"})
      insert(:follow, follower: insert(:user, email_confirmed?: true), followee: user)

      html = conn |> get(~p"/#{user}") |> html_response(200)

      assert card_title(html, "profile-addresses") == "Address"
      assert card_title(html, "profile-links") == "Link"
      assert card_title(html, "profile-posts") == "Post"
      assert card_title(html, "profile-followers") == "Follower"
    end

    test "read plural when a section holds more than one entry", %{conn: conn} do
      user = insert_activated_user()
      insert(:phone_number, user: user, value: "+49 30 5551234")
      insert(:phone_number, user: user, value: "+49 30 5559999")
      insert(:address, user: user, city: "Berlin")
      insert(:address, user: user, city: "Hamburg")
      insert(:url, user: user, value: "https://example.org/a", description: "Site A")
      insert(:url, user: user, value: "https://example.org/b", description: "Site B")
      {:ok, _} = Vutuv.Posts.create_post(user, %{body: "first post"})
      {:ok, _} = Vutuv.Posts.create_post(user, %{body: "second post"})
      insert(:follow, follower: insert(:user, email_confirmed?: true), followee: user)
      insert(:follow, follower: insert(:user, email_confirmed?: true), followee: user)

      html = conn |> get(~p"/#{user}") |> html_response(200)

      assert card_title(html, "profile-addresses") == "Addresses"
      assert card_title(html, "profile-links") == "Links"
      assert card_title(html, "profile-posts") == "Posts"
      assert card_title(html, "profile-followers") == "Followers"
    end

    test "German titles switch between singular and plural too", %{conn: conn} do
      # The screenshot that prompted this fix was German ("TELEFONNUMMERN" /
      # "ADRESSEN"); guard the German plural forms in the .po, not just the
      # English ngettext wiring.
      one = insert_activated_user()
      insert(:phone_number, user: one, value: "+49 30 5551234")
      insert(:address, user: one, city: "Berlin")
      {:ok, _} = Vutuv.Posts.create_post(one, %{body: "einziger Beitrag"})

      many = insert_activated_user()
      insert(:phone_number, user: many, value: "+49 30 5551234")
      insert(:phone_number, user: many, value: "+49 30 5559999")
      insert(:address, user: many, city: "Berlin")
      insert(:address, user: many, city: "Hamburg")
      {:ok, _} = Vutuv.Posts.create_post(many, %{body: "erster Beitrag"})
      {:ok, _} = Vutuv.Posts.create_post(many, %{body: "zweiter Beitrag"})

      de = put_req_header(conn, "accept-language", "de")

      singular = de |> get(~p"/#{one}") |> html_response(200)
      assert card_title(singular, "profile-addresses") == "Adresse"
      assert card_title(singular, "profile-posts") == "Beitrag"

      plural = de |> get(~p"/#{many}") |> html_response(200)
      assert card_title(plural, "profile-addresses") == "Adressen"
      assert card_title(plural, "profile-posts") == "Beiträge"
    end
  end

  test "hides the country of a German address from a de viewer and links to maps",
       %{conn: conn} do
    user = insert_activated_user()

    insert(:address,
      user: user,
      description: "Office",
      line_1: "Johannes-Müller-Str. 10",
      zip_code: "56068",
      city: "Koblenz",
      country: "Germany"
    )

    html =
      conn
      |> put_req_header("accept-language", "de")
      |> get(~p"/#{user}")
      |> html_response(200)

    assert html =~ "Koblenz"
    # A German viewer looking at a German address does not need "Deutschland".
    refute html =~ "Deutschland"

    # Every address links out to the major map services.
    assert html =~ "https://www.google.com/maps/search/"
    assert html =~ "https://www.openstreetmap.org/search"
    assert html =~ "https://maps.apple.com/"
    # For a logged-out viewer the default (Google Maps) is the single primary
    # call to action; the other services are demoted to a quiet "also on" line
    # so the row reads as one map action (Vutuv.Maps).
    assert html =~ "In Google Maps öffnen"
    assert html =~ "Auch auf"
    assert html =~ "OpenStreetMap"
    assert html =~ "Apple Maps"
    # A logged-out viewer cannot promote a default, so the row carries no
    # persist hook (the click-to-promote enhancement stays off).
    refute html =~ "data-map-persist-url"
  end

  test "renders the viewer's chosen default map service as the primary button", %{conn: conn} do
    {conn, viewer} = create_and_login_user(conn)
    {:ok, _} = Vutuv.Accounts.update_user(viewer, %{"default_map_service" => "apple"})

    owner = insert_activated_user()
    insert(:address, user: owner, description: "Office", city: "Koblenz", country: "Germany")

    html = conn |> get(~p"/#{owner}") |> html_response(200)

    # The viewer defaulted to Apple Maps, so that is the primary "Open in …"
    # button; the row carries the persist hook so a click promotes a new default.
    assert html =~ "Open in Apple Maps"
    assert html =~ "data-map-persist-url"
    assert html =~ ~s(data-service="apple")
  end

  test "shows no map buttons when the viewer has disabled every map service", %{conn: conn} do
    {conn, viewer} = create_and_login_user(conn)

    {:ok, _} =
      Vutuv.Accounts.update_user(viewer, %{
        "map_google?" => "false",
        "map_openstreetmap?" => "false",
        "map_apple?" => "false"
      })

    owner = insert_activated_user()
    insert(:address, user: owner, description: "Office", city: "Koblenz", country: "Germany")

    html = conn |> get(~p"/#{owner}") |> html_response(200)

    # The address itself still shows; only the map links are gone.
    assert html =~ "Koblenz"
    refute html =~ "https://maps.apple.com/"
    refute html =~ "data-map-row"
  end

  test "keeps the country line of a German address for a non-de viewer", %{conn: conn} do
    user = insert_activated_user()
    insert(:address, user: user, description: "Office", city: "Koblenz", country: "Germany")

    html =
      conn
      |> put_req_header("accept-language", "en")
      |> get(~p"/#{user}")
      |> html_response(200)

    assert html =~ "Koblenz"
    assert html =~ "Deutschland"
  end

  test "viewing the profile of a member who follows you renders their private email",
       %{conn: conn} do
    {conn, viewer} = create_and_login_user(conn)

    owner = insert_activated_user(first_name: "Paula", last_name: "Permissions")
    insert(:email, user: owner, value: "paula.private@example.com", public?: false)

    # The owner follows the viewer, so the viewer is permitted to see the
    # owner's private email. user_has_permissions?/2 returns the follow id (a
    # truthy UUID, not a strict boolean); it used to leak into profile_emails/3
    # — which only matches true/false — and 500 the whole profile page.
    insert(:follow, follower: owner, followee: viewer)

    html = conn |> get(~p"/#{owner}") |> html_response(200)

    assert html =~ "paula.private@example.com"
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

  test "renders a tag's endorsement count as an inline pill with a clickable endorser roster",
       %{conn: conn} do
    owner = insert_activated_user(username: "tag.pill.owner")

    endorser =
      insert_activated_user(
        username: "tag.pill.endorser",
        first_name: "Ada",
        last_name: "Lovelace"
      )

    user_tag = insert(:user_tag, user: owner, tag: insert(:tag, name: "Elixir", slug: "elixir"))
    insert(:user_tag_endorsement, user_tag: user_tag, user: endorser)

    html = conn |> get(~p"/#{owner}") |> html_response(200)

    # The visible count reads as the calm brand-tint inline pill (the chosen design),
    # in the chip flow — not the old floating corner badge.
    assert html =~ "rounded-full bg-brand-100 px-1"

    # The hover roster lists the endorser as a link to their profile (clickable people);
    # the endorser has no tag of their own, so they never leak into "Who to follow".
    assert html =~ ~s(href="/tag.pill.endorser")
    assert html =~ "Ada Lovelace"
  end

  test "a logged-in visitor gets the count pill as an endorse toggle, with a + on zero-count tags",
       %{conn: conn} do
    owner = insert_activated_user(username: "endorse.pill.owner")

    # One tag already endorsed (count 1) and one with no endorsements (count 0).
    voted = insert(:user_tag, user: owner, tag: insert(:tag, name: "Elixir", slug: "elixir"))
    insert(:user_tag_endorsement, user_tag: voted, user: insert_activated_user())
    insert(:user_tag, user: owner, tag: insert(:tag, name: "Erlang", slug: "erlang"))

    {conn, _visitor} = create_and_login_user(conn)
    html = conn |> get(~p"/#{owner}") |> html_response(200)

    # The pill itself is the CSRF endorse toggle now (not a read-only span).
    assert html =~ "data-tag-vote"
    assert html =~ "data-tag-vote-count"
    # The zero-count tag (Erlang) shows a "+" so there is something to click.
    assert html =~ ~r/data-tag-vote-count[^>]*>\s*\+/
  end

  test "the hover roster pre-renders the viewer's own row (hidden) so endorsing reveals it",
       %{conn: conn} do
    # A tag with another endorser, but the visitor has not endorsed it yet. Their own
    # roster row is rendered up front and hidden, ready for the JS toggle to reveal it
    # without a page reload (so they see themselves in the roster the moment they vote).
    owner = insert_activated_user(username: "roster.owner")
    user_tag = insert(:user_tag, user: owner, tag: insert(:tag, name: "Elixir", slug: "elixir"))
    insert(:user_tag_endorsement, user_tag: user_tag, user: insert_activated_user())

    {conn, _visitor} = create_and_login_user(conn)
    html = conn |> get(~p"/#{owner}") |> html_response(200)

    assert [self_li] = Regex.run(~r/<li[^>]*data-self-endorser[^>]*>/, html)
    assert self_li =~ "hidden"
  end

  test "the viewer's own roster row shows (unhidden) on a tag they have already endorsed",
       %{conn: conn} do
    owner = insert_activated_user(username: "roster.owner2")
    user_tag = insert(:user_tag, user: owner, tag: insert(:tag, name: "Elixir", slug: "elixir"))

    {conn, visitor} = create_and_login_user(conn)
    insert(:user_tag_endorsement, user_tag: user_tag, user: visitor)

    html = conn |> get(~p"/#{owner}") |> html_response(200)

    assert [self_li] = Regex.run(~r/<li[^>]*data-self-endorser[^>]*>/, html)
    refute self_li =~ "hidden"
    # ...and the roster lists the viewer by name.
    assert html =~ VutuvWeb.UserHelpers.full_name(visitor)
  end

  test "hides empty profile sections from visitors", %{conn: conn} do
    user = insert_activated_user()

    conn = get(conn, ~p"/#{user}")
    html = html_response(conn, 200)

    refute html =~ ~s(id="profile-contact")
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
    # their new-entry form. Contact already holds the registration e-mail, so it
    # shows that e-mail plus the "Add a phone number" tile (e-mail and phone
    # share one card now) and a "Manage emails" footer.
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
    conn = get(conn, ~p"/#{%User{username: "1"}}")
    assert html_response(conn, :not_found)
  end

  test "renders form for editing chosen resource", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    html = conn |> get(~p"/#{user}/edit") |> html_response(200)
    # The slimmed edit page is the profile content only, grouped into sections.
    assert html =~ "Your name"
    assert html =~ "First Name"
    # The obscure honorific fields carry an example placeholder, like the
    # registration form does for its fields, so their meaning is obvious.
    assert html =~ "e.g. Dr. or Prof."
    assert html =~ "e.g. Jr. or PhD"
  end

  test "the Photos section previews the current avatar, and the cover only when set",
       %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    # The avatar preview always reflects the live state (the initials tile when
    # there is no upload), so the owner sees what visitors currently see before
    # picking a replacement.
    html = conn |> get(~p"/#{user}/edit") |> html_response(200)
    assert html =~ "Current avatar"
    # No cover uploaded yet, so no cover preview (we don't preview the gradient
    # placeholder as if it were a photo).
    refute html =~ "Current cover photo"

    # Once a cover photo exists, it is shown above the upload field.
    {:ok, _} = user |> Ecto.Changeset.change(cover_photo: "cover.avif") |> Repo.update()
    html = conn |> recycle() |> get(~p"/#{user}/edit") |> html_response(200)
    assert html =~ "Current cover photo"
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

  test "the privacy page asks the search-engine and the AI question separately", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    html = conn |> get(~p"/#{user}/settings/privacy") |> html_response(200)

    # The two consents now live on the Privacy tab as positively-framed
    # checkboxes (the field is the opt-out noindex?/noai?, the box is "Allow").
    assert html =~ "Allow search engines to index your profile"
    assert html =~ "Allow AI agents and LLMs to use your profile"
  end

  test "the account hub carries a clear, confirmed Delete account control", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    html = conn |> get(~p"/#{user}/settings") |> html_response(200)

    assert html =~ "Delete account"
    # The consequence is spelled out before the user acts...
    assert html =~ "cannot be undone"
    # ...and the control is the canonical red danger button with a confirm
    # dialog (id pinned so the shell's logout delete-link doesn't match).
    assert html =~ ~s(id="delete-account")
    assert html =~ "data-confirm"

    # The GDPR export stays reachable from the hub.
    assert html =~ ~s(href="#{~p"/#{user}/export"}")
  end

  test "the otherwise-unfindable account & privacy pages are reachable from settings", %{
    conn: conn
  } do
    {conn, user} = create_and_login_user(conn)

    # Blocked members and the owner's moderation cases now live on the Privacy
    # tab under a "Safety" card, where members look for them (both used to be in
    # the account hub, blocking under a mislabelled "Privacy & security" card).
    privacy = conn |> get(~p"/#{user}/settings/privacy") |> html_response(200)
    assert privacy =~ ~s(href="#{~p"/blocks"}")
    assert privacy =~ ~s(href="#{~p"/moderation/cases"}")

    # Connected apps and API tokens moved to their own Apps tab, reachable only
    # from there for a normal user (no shell or profile link).
    apps = conn |> recycle() |> get(~p"/#{user}/settings/apps") |> html_response(200)
    assert apps =~ ~s(href="#{~p"/connected_apps"}")
    assert apps =~ ~s(href="#{~p"/access_tokens"}")
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

  test "the edit form has no email inputs; the account hub links to email management", %{
    conn: conn
  } do
    {conn, user} = create_and_login_user(conn)

    edit = conn |> get(~p"/#{user}/edit") |> html_response(200)
    refute edit =~ "user[emails]"

    # Email management (a PIN-verified flow) lives on the account hub now.
    hub = conn |> recycle() |> get(~p"/#{user}/settings") |> html_response(200)
    assert hub =~ ~p"/#{user}/emails"
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
    # The edit form re-renders (422) with its grouped sections intact.
    assert html_response(conn, 422) =~ "Your name"
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

  describe "owner 'view as' profile preview" do
    # Two emails so the private/public split is unambiguous: the owner and a
    # a connection (vernetzt, mutual follow) see both, a plain Follower / the
    # public see only the public one.
    defp owner_with_emails(conn) do
      {conn, user} = create_and_login_user(conn)
      insert(:email, user: user, value: "secret@example.com", public?: false)
      insert(:email, user: user, value: "shown@example.com", public?: true)
      {conn, user}
    end

    test "owner's default view carries the switcher and the full private profile", %{conn: conn} do
      {conn, user} = owner_with_emails(conn)

      html = conn |> get(~p"/#{user}") |> html_response(200)

      # The switcher is the persistent entry point; no banner until a preview
      # is active.
      assert html =~ "view-as-switcher"
      refute html =~ "view-as-banner"
      # The switcher is rendered once from the app layout; on the profile its
      # segments target the bare profile path (base_path = conn.request_path).
      assert html =~ ~p"/#{user}?#{[view_as: "follower"]}"
      assert html =~ ~p"/#{user}?#{[view_as: "public"]}"
      # The profile grid is full width, so the bar spans the full main column
      # (max-w-6xl); the section pages get the narrower max-w-3xl instead.
      assert html =~ "mt-6 max-w-6xl"
      assert html =~ "Edit profile"
      assert html =~ "secret@example.com"
      assert html =~ "shown@example.com"
    end

    test "previewing as a Follower hides private emails and owner chrome but shows visitor controls",
         %{conn: conn} do
      {conn, user} = owner_with_emails(conn)

      html = conn |> get(~p"/#{user}?#{[view_as: "follower"]}") |> html_response(200)

      assert html =~ "view-as-banner"
      refute html =~ "Edit profile"
      # A plain follower is not someone the owner follows, so no private email.
      refute html =~ "secret@example.com"
      assert html =~ "shown@example.com"
      # The action controls render (inert in preview): the Message link to this
      # profile only appears in the header control cluster.
      assert html =~ ~p"/messages/with/#{user}"
      assert html =~ "pointer-events-none"
    end

    test "previewing as a connection (vernetzt) reveals private emails too", %{conn: conn} do
      {conn, user} = owner_with_emails(conn)

      html = conn |> get(~p"/#{user}?#{[view_as: "connection"]}") |> html_response(200)

      assert html =~ "view-as-banner"
      refute html =~ "Edit profile"
      # A connection is a mutual follow, so the owner follows them and the
      # private-email rule grants it.
      assert html =~ "secret@example.com"
      assert html =~ "shown@example.com"
      assert html =~ ~p"/messages/with/#{user}"
    end

    test "previewing as the public hides private data, owner chrome and every action control",
         %{conn: conn} do
      {conn, user} = owner_with_emails(conn)

      html = conn |> get(~p"/#{user}?#{[view_as: "public"]}") |> html_response(200)

      assert html =~ "view-as-banner"
      refute html =~ "Edit profile"
      refute html =~ "secret@example.com"
      assert html =~ "shown@example.com"
      refute html =~ ~p"/messages/with/#{user}"
      # This member allows indexing and AI, so the banner makes no exception
      # and there is no link to the privacy settings.
      refute html =~ ~p"/#{user}/settings/privacy"
    end

    test "public preview links to privacy settings when indexing or AI use is restricted",
         %{conn: conn} do
      # The public banner says search engines see the page, but this member has
      # turned indexing off (noai? is the symmetric case), so the banner adds a
      # "More about this." link to the privacy page that explains/manages it.
      {conn, user} = owner_with_emails(conn)
      user = user |> change(noindex?: true) |> Repo.update!()

      html = conn |> get(~p"/#{user}?#{[view_as: "public"]}") |> html_response(200)

      assert html =~ "More about this."
      assert html =~ ~p"/#{user}/settings/privacy"
    end

    test "post visibility follows the previewed relationship", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, _} = Vutuv.Posts.create_post(user, %{body: "everyone post"})

      {:ok, _} =
        Vutuv.Posts.create_post(user, %{
          body: "followers post",
          denials: [%{"wildcard" => "non_followers"}]
        })

      {:ok, _} =
        Vutuv.Posts.create_post(user, %{
          body: "connections post",
          denials: [%{"wildcard" => "non_connections"}]
        })

      public = conn |> get(~p"/#{user}?#{[view_as: "public"]}") |> html_response(200)
      assert public =~ "everyone post"
      refute public =~ "followers post"
      refute public =~ "connections post"

      follower = conn |> get(~p"/#{user}?#{[view_as: "follower"]}") |> html_response(200)
      assert follower =~ "everyone post"
      assert follower =~ "followers post"
      refute follower =~ "connections post"

      connection = conn |> get(~p"/#{user}?#{[view_as: "connection"]}") |> html_response(200)
      assert connection =~ "everyone post"
      assert connection =~ "followers post"
      assert connection =~ "connections post"
    end

    test "a stranger's ?view_as= is ignored: no switcher, no preview, no leak", %{conn: conn} do
      {conn, _visitor} = create_and_login_user(conn)
      owner = insert_activated_user()
      insert(:email, user: owner, value: "secret@example.com", public?: false)

      html = conn |> get(~p"/#{owner}?#{[view_as: "connection"]}") |> html_response(200)

      refute html =~ "view-as-switcher"
      refute html =~ "view-as-banner"
      refute html =~ "secret@example.com"
    end
  end

  defp search_term_values(user) do
    user
    |> Ecto.assoc(:search_terms)
    |> Repo.all()
    |> Enum.map(& &1.value)
  end
end
