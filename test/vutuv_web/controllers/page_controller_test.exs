defmodule VutuvWeb.PageControllerTest do
  use VutuvWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  describe "GET / when logged in" do
    # "/" is the logged-out landing page (sign-up). A member who is already
    # logged in has no business there, so RequireUserLoggedOut bounces them to
    # their home: the newsfeed once they follow someone, otherwise their own
    # profile so a brand-new member never lands on an empty feed (VutuvWeb.Home).
    test "sends a member who follows someone to the feed", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      insert(:follow, follower: user, followee: insert(:activated_user))

      conn = get(conn, ~p"/")

      assert redirected_to(conn) == ~p"/feed"
    end

    test "sends a member who follows nobody to their profile", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn = get(conn, ~p"/")

      assert redirected_to(conn) == ~p"/#{user}"
    end
  end

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
      # kept out of search by the page-level X-Robots-Tag: noindex header
      # (VutuvWeb.Plug.NoIndex), NOT a robots block — a Disallow only stops
      # crawling, so a linked detail URL would still be indexed as a bare link
      # and could never be crawled to see the noindex. So they stay crawlable.
      refute body =~ "Disallow: /*/emails"
      refute body =~ "Disallow: /*/addresses"

      # The legacy /users/... URLs are 301 redirects and stay crawlable, so the
      # redirect consolidates them onto the canonical /:slug profile instead of
      # leaving the old URL stranded in the index.
      refute body =~ "Disallow: /users/"
    end

    test "names the AI crawlers and declares Content-Signals (permissive stance)" do
      body = build_conn() |> get("/robots.txt") |> response(200)

      assert body =~ "User-agent: GPTBot"
      assert body =~ "User-agent: ClaudeBot"
      assert body =~ "Content-Signal: ai-train=yes, search=yes, ai-input=yes"
      assert body =~ "Sitemap: http://localhost:4001/sitemap.xml"
    end
  end

  describe "GET /llms.txt" do
    test "documents the discovery surface: sitemap, feeds, well-known, headers" do
      body = build_conn() |> get("/llms.txt") |> response(200)

      assert body =~ "/sitemap.xml"
      assert body =~ "/posts/feed.xml"
      assert body =~ "/.well-known/agent-skills/index.json"
      assert body =~ "/.well-known/security.txt"
      assert body =~ "Link"
      assert body =~ "Content-Location"
    end

    test "lists the policy pages, including the Nutzungsbedingungen" do
      body = build_conn() |> get("/llms.txt") |> response(200)

      assert body =~ "/nutzungsbedingungen"
      assert body =~ "/datenschutzerklaerung"
      assert body =~ "/impressum"
      assert body =~ "/community"
    end
  end

  describe "GET /nutzungsbedingungen" do
    test "renders a neutral placeholder while the operator wrote nothing yet",
         %{conn: conn} do
      body = conn |> get(~p"/nutzungsbedingungen") |> html_response(200)

      assert body =~ "Nutzungsbedingungen"
      assert body =~ "not published this page yet"
      # No operator identity leaks from the old hardcoded template (the
      # organization name itself stays in the shared footer, so probe the street).
      refute body =~ "Johannes-Müller-Str."
    end

    test "renders the terms of use page", %{conn: conn} do
      seed_legal!("nutzungsbedingungen")
      body = conn |> get(~p"/nutzungsbedingungen") |> html_response(200)

      assert body =~ "Nutzungsbedingungen"
      # Operator identity matches the Impressum / Datenschutzerklärung.
      assert body =~ "Wintermeyer Consulting"
      # A few load-bearing sections of the actual terms.
      assert body =~ "Haftung"
      assert body =~ "Schlussbestimmungen"
      # The Markdown body arrives rendered, not as raw source.
      assert body =~ "<h3"
      refute body =~ "### §"
      # It is finished text now, not a marked-up draft.
      refute body =~ "noch nicht rechtsverbindlich"
    end
  end

  describe "GET /datenschutzerklaerung" do
    test "renders the vutuv.de privacy policy once seeded", %{conn: conn} do
      seed_legal!("datenschutzerklaerung")
      body = conn |> get(~p"/datenschutzerklaerung") |> html_response(200)

      # The honest, upfront note leads the page: vutuv only works if people
      # show something of themselves.
      assert body =~ "Ein ehrliches Wort vorab"
      # Our core promises live near the top: own servers in Germany, nothing
      # handed to third parties.
      assert body =~ "eigene Server in Deutschland"
      assert body =~ "keine Weitergabe an Dritte"
      # The responsible party stays Wintermeyer Consulting (same as the Impressum).
      assert body =~ "Wintermeyer Consulting"

      # vutuv describes itself generically as a social network, not a
      # profession-specific contact network.
      assert body =~ "soziales Netzwerk"
      refute body =~ "berufliches Kontaktnetzwerk"

      # Trust-building: the policy points at the open-source code so claims can
      # be verified.
      assert body =~ "Open Source"
      assert body =~ ~s(href="https://github.com/wintermeyer/vutuv")

      # The persisted, behaviour-related processing must be disclosed: the
      # per-user search history, the slug (profile-address) history and the live
      # online status. Usage/dwell tracking is only planned, not active, so it
      # must NOT be described here yet (it gets added when the feature ships).
      assert body =~ "Such-Verlauf"
      assert body =~ "Verlauf Ihrer Profil-Adressen"
      assert body =~ "Online-Status"
      refute body =~ "Verweildauer"

      # Recording session device/IP/location for the signed-in-devices feature
      # and the new-device security email is a data-protection change that must
      # be disclosed (issues #794 / #786).
      assert body =~ "Angemeldete Geräte"
      assert body =~ "User-Agent"

      # Follow-only federation must be disclosed: opt-in, follower addresses
      # stored, public posts delivered, remote deletion not enforceable.
      assert body =~ "Fediverse (ActivityPub)"
      assert body =~ "nicht erzwingen"

      # The old generic shop/e-commerce boilerplate is gone for good: vutuv has
      # no shopping cart, ships no goods and runs no third-party transport.
      refute body =~ "Warenkorb"
      refute body =~ "Transportunternehmen"
    end

    # External target="_blank" links leak window.opener to the destination and
    # can be abused for reverse tabnabbing. The page no longer carries any such
    # links, but should one ever return it must keep rel="noopener noreferrer".
    test "any external target=_blank links carry rel=noopener noreferrer" do
      seed_legal!("datenschutzerklaerung")
      body = build_conn() |> get(~p"/datenschutzerklaerung") |> html_response(200)

      for [anchor] <- Regex.scan(~r/<a[^>]*target="_blank"[^>]*>/, body) do
        assert anchor =~ ~s(rel="noopener noreferrer"),
               "expected rel=noopener noreferrer on #{anchor}"
      end
    end
  end

  describe "GET /username" do
    # People copy the literal word "username" out of instructions ("your profile
    # lives at vutuv.de/username") and paste it into the address bar. Rather than
    # a bare 404, /username explains that it is a placeholder for the person's
    # real handle and points at a concrete example. "username" is a ReservedSlug
    # so no member can ever claim it and shadow this page.
    test "explains the placeholder instead of showing a bare 404", %{conn: conn} do
      # 404 status: there is no page or member literally called "username".
      body = conn |> get(~p"/username") |> html_response(404)

      # It names the placeholder and links a real example profile.
      assert body =~ "username"
      assert body =~ "wintermeyer"
      assert body =~ ~s(href="https://vutuv.de/wintermeyer")
    end

    # The German username help text points at vutuv.de/benutzername, so the
    # German placeholder gets the same helper page.
    test "the German placeholder /benutzername shows the same helper", %{conn: conn} do
      body = conn |> get(~p"/benutzername") |> html_response(404)

      assert body =~ ~s(href="https://vutuv.de/wintermeyer")
    end

    test "renders the placeholder page even when members are registered",
         %{conn: conn} do
      # A registered member must not change what /username shows: the route
      # wins over the /:slug catch-all by definition order, and the page is a
      # static template that never consults the database.
      insert(:activated_user)

      body = conn |> get(~p"/username") |> html_response(404)

      assert body =~ ~s(href="https://vutuv.de/wintermeyer")
    end
  end

  describe "GET /{{username}} (the unsubstituted newsletter merge tag)" do
    # The July 2026 newsletter shipped its profile link with the {{username}}
    # merge tag unsubstituted inside the href, so 3,075 inboxes hold a link to
    # /%7B%7Busername%7D%7D. Phoenix matches routes on percent-decoded
    # segments, so a literal /{{username}} route catches those clicks: a
    # logged-in member is taken where the newsletter meant to send them -
    # their own profile - and everyone else gets the placeholder explanation.
    test "redirects a logged-in member to their own profile", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn = get(conn, "/%7B%7Busername%7D%7D")

      assert redirected_to(conn) == ~p"/#{user}"
    end

    test "shows the placeholder helper to an anonymous visitor", %{conn: conn} do
      body = conn |> get("/%7B%7Busername%7D%7D") |> html_response(404)

      assert body =~ ~s(href="https://vutuv.de/wintermeyer")
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

  describe "GET / founder attribution" do
    # The founder's name under the landing-page quote links to his vutuv
    # profile so visitors can see a real account behind the welcome.
    test "links the founder name to his vutuv profile", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)

      assert body =~ ~s(href="https://vutuv.de/wintermeyer")
      assert body =~ "Stefan Wintermeyer"
    end
  end

  describe "GET / sign-up opt-in checkboxes" do
    # All three opt-in boxes on the sign-up form are framed positively (you
    # grant a permission by checking) and all three start CHECKED. Showing the
    # address on your profile is what most members want, so the sign-up form now
    # defaults the email-visibility box ON; the schema default stays private, so
    # any other code path that creates an email without a choice still keeps it
    # private. Being findable is the point of the product, so the indexing box
    # stays checked; it is wired to the inverted `noindex?` field: checked means
    # "allow indexing" (noindex? = false). The AI box works the same way on the
    # inverted `noai?` field.
    test "are positively framed and all checked by default", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)

      # Positive, parallel phrasing; the old negative "Prevent ..." copy is gone.
      assert body =~ "Allow others to view your email address"
      assert body =~ "Allow search engines to index your profile"
      assert body =~ "Allow AI agents and LLMs to use your profile"
      refute body =~ "Prevent search engines from indexing your profile"

      assert checkbox_checked?(body, "user[emails][0][public?]")
      assert checkbox_checked?(body, "user[noindex?]")
      assert checkbox_checked?(body, "user[noai?]")
    end

    # The email-type chooser is a radio group (clearer for a normal user than
    # the old dropdown, whose unhelpful "Other" default it replaces). It reads
    # Privat, Arbeit, Andere - the order of Vutuv.Accounts.Email.email_types/0 -
    # and preselects "Personal", the address most people sign up with.
    test "email type is a Personal-preselected radio group", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)

      assert radio_checked?(body, "user[emails][0][email_type]", "Personal")
      refute radio_checked?(body, "user[emails][0][email_type]", "Work")
      refute radio_checked?(body, "user[emails][0][email_type]", "Other")

      # Order matters as much as the default: the private option comes first.
      assert [{"Personal", _}, {"Work", _}, {"Other", _}] =
               Regex.scan(~r/value="(Personal|Work|Other)"/, body)
               |> Enum.map(fn [whole, value] -> {value, whole} end)
    end

    # Gender is a radio group too (no empty "Choose a gender" prompt) and
    # preselects "male" / männlich.
    test "gender is a male-preselected radio group", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)

      assert radio_checked?(body, "user[gender]", "male")
      refute radio_checked?(body, "user[gender]", "female")
      refute radio_checked?(body, "user[gender]", "other")
    end

    # The consent line by the submit button accepts the Nutzungsbedingungen
    # (AGB incorporation, §305 BGB) and links the Datenschutzerklärung (GDPR
    # Art. 13 information duty), both as links rather than separate checkboxes.
    test "links the terms and privacy policy near the sign-up button", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)

      assert body =~ ~s(href="/nutzungsbedingungen")
      assert body =~ ~s(href="/datenschutzerklaerung")
      assert body =~ "accept our"
    end
  end

  describe "POST /new_registration" do
    # Checking the (inverted) indexing box submits "false", which must land as a
    # search-indexable profile.
    test "checking the indexing box stores an indexable profile", %{conn: conn} do
      attrs =
        Map.merge(valid_attrs(), %{
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
        Map.merge(valid_attrs(), %{
          "emails" => %{"0" => %{"value" => "hidden@example.com"}},
          "noindex?" => "true"
        })

      post(conn, ~p"/new_registration", user: attrs)

      assert user_by_email("hidden@example.com").noindex? == true
    end

    # The AI box is the same inverted mechanism on `noai?`. The two choices
    # are independent: search engines yes plus AI no (and vice versa) must
    # both land exactly as submitted.
    test "the AI box stores the member's choice independently of indexing", %{conn: conn} do
      attrs =
        Map.merge(valid_attrs(), %{
          "emails" => %{"0" => %{"value" => "search_only@example.com"}},
          "noindex?" => "false",
          "noai?" => "true"
        })

      post(conn, ~p"/new_registration", user: attrs)

      user = user_by_email("search_only@example.com")
      assert user.noindex? == false
      assert user.noai? == true

      attrs =
        Map.merge(valid_attrs(), %{
          "emails" => %{"0" => %{"value" => "ai_only@example.com"}},
          "noindex?" => "true",
          "noai?" => "false"
        })

      post(build_conn(), ~p"/new_registration", user: attrs)

      user = user_by_email("ai_only@example.com")
      assert user.noindex? == true
      assert user.noai? == false
    end

    # Privacy by default: an untouched email box (the hidden "false") stores a
    # private address; ticking it is the explicit opt-in to a public one.
    test "the email address stays private unless the box is ticked", %{conn: conn} do
      attrs =
        Map.merge(valid_attrs(), %{
          "emails" => %{"0" => %{"value" => "private@example.com", "public?" => "false"}}
        })

      post(conn, ~p"/new_registration", user: attrs)

      user = user_by_email("private@example.com") |> Vutuv.Repo.preload(:emails)
      refute hd(user.emails).public?
    end

    test "ticking the email box stores a public address", %{conn: conn} do
      attrs =
        Map.merge(valid_attrs(), %{
          "emails" => %{"0" => %{"value" => "open@example.com", "public?" => "true"}}
        })

      post(conn, ~p"/new_registration", user: attrs)

      user = user_by_email("open@example.com") |> Vutuv.Repo.preload(:emails)
      assert hd(user.emails).public?
    end

    # A tampered/malformed "emails" param (a bare string instead of the nested
    # %{"0" => %{"value" => …}} map the form builds) must re-render the form,
    # not 500 on chained Access indexing.
    test "a malformed emails param re-renders the form instead of crashing", %{conn: conn} do
      attrs = %{"emails" => "x", "first_name" => "Foo", "tag_list" => registration_tags()}

      conn = post(conn, ~p"/new_registration", user: attrs)

      assert html_response(conn, 422)
    end

    # The sign-up form's "Your tags" field must actually land as user tags;
    # it used to be cast into the virtual `tag_list` and silently dropped.
    test "creates user tags from the comma-separated tag list", %{conn: conn} do
      elixir = unique_tag_name("Elixir")
      cooking = unique_tag_name("Cooking")
      origami = unique_tag_name("Origami")

      attrs =
        Map.merge(valid_attrs(), %{
          "emails" => %{"0" => %{"value" => "tagged@example.com"}},
          "tag_list" => " #{elixir},  #{cooking} , #{origami}, "
        })

      post(conn, ~p"/new_registration", user: attrs)

      user = user_by_email("tagged@example.com") |> Vutuv.Repo.preload(user_tags: :tag)
      expected = Enum.sort(Enum.map([elixir, cooking, origami], &String.downcase/1))

      assert user.user_tags
             |> Enum.map(&String.downcase(&1.tag.name))
             |> Enum.sort() == expected
    end

    # Tags are a cornerstone of the system, so a sign-up needs at least three
    # distinct ones. A short (or blank) tag list re-renders the form with the
    # error instead of creating the account.
    test "a blank tag list is rejected", %{conn: conn} do
      attrs =
        Map.merge(valid_attrs(), %{
          "emails" => %{"0" => %{"value" => "untagged@example.com"}},
          "tag_list" => "   "
        })

      conn = post(conn, ~p"/new_registration", user: attrs)

      assert html_response(conn, 422) =~ "Please enter at least 3 different tags."
      refute user_by_email("untagged@example.com")
    end

    # The failed re-render marks the field itself, not just the page: the
    # errored input turns red (aria-invalid for assistive tech), the specific
    # error replaces the generic hint (never both, they'd say the same thing
    # twice), and the banner points at the red marking instead of apologizing
    # about a "validation error".
    test "a rejected sign-up marks the tag field itself", %{conn: conn} do
      attrs =
        Map.merge(valid_attrs(), %{
          "emails" => %{"0" => %{"value" => "marked@example.com"}},
          "tag_list" => unique_tag_name("Elixir")
        })

      body = conn |> post(~p"/new_registration", user: attrs) |> html_response(422)

      assert body =~ "Please check the fields marked in red."
      assert body =~ ~s(aria-invalid="true")
      assert body =~ "border-red-400"
      # The hint yields to the specific error instead of stacking under it.
      assert body =~ "Please enter at least 3 different tags."
      refute body =~ "At least three tags, separated by a comma or a space."
    end

    test "a fresh form shows the hint and no error chrome", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)

      assert body =~ "At least three tags, separated by a comma or a space."
      refute body =~ "Please check the fields marked in red."
      refute body =~ ~s(aria-invalid="true")
      refute body =~ "border-red-400"
    end

    test "fewer than three distinct tags is rejected, counting duplicates once", %{conn: conn} do
      name = unique_tag_name("Elixir")
      other = unique_tag_name("Cooking")

      attrs =
        Map.merge(valid_attrs(), %{
          "emails" => %{"0" => %{"value" => "duplicated@example.com"}},
          "tag_list" => "#{name}, #{String.downcase(name)}, #{String.upcase(name)}, #{other}"
        })

      conn = post(conn, ~p"/new_registration", user: attrs)

      assert html_response(conn, 422) =~ "Please enter at least 3 different tags."
      refute user_by_email("duplicated@example.com")
    end

    # An unquoted run of words is not an error: each word (and each
    # comma-separated segment) becomes its own tag. A quoted phrase is kept
    # whole (see the next test and Vutuv.Tags.parse_tag_names/1).
    test "splits a space-separated tag list into one tag per word", %{conn: conn} do
      javascript = unique_tag_name("JavaScript")
      go = unique_tag_name("Go")
      hunde = unique_tag_name("Hunde")

      attrs =
        Map.merge(valid_attrs(), %{
          "emails" => %{"0" => %{"value" => "spaced@example.com"}},
          "tag_list" => "#{javascript} #{go} #{hunde}"
        })

      post(conn, ~p"/new_registration", user: attrs)

      user = user_by_email("spaced@example.com") |> Vutuv.Repo.preload(user_tags: :tag)

      assert user.user_tags
             |> Enum.map(& &1.tag.name)
             |> Enum.sort() == Enum.sort([javascript, go, hunde])
    end

    test "keeps a quoted multi-word tag whole at sign-up", %{conn: conn} do
      n = System.unique_integer([:positive])
      rails = "Ruby on Rails #{n}"
      elixir = "Elixir#{n}"
      go = "Go#{n}"

      attrs =
        Map.merge(valid_attrs(), %{
          "emails" => %{"0" => %{"value" => "quoted@example.com"}},
          "tag_list" => ~s("#{rails}", #{elixir}, #{go})
        })

      post(conn, ~p"/new_registration", user: attrs)

      user = user_by_email("quoted@example.com") |> Vutuv.Repo.preload(user_tags: :tag)

      assert user.user_tags
             |> Enum.map(& &1.tag.name)
             |> Enum.sort() == Enum.sort([rails, elixir, go])
    end

    # The PIN-entry confirmation page shown right after sign-up used to point at
    # the dead @vutuv Twitter account. The whole "Updates about vutuv" line is
    # gone; the PIN form and its instructions must stay untouched.
    test "the PIN confirmation page no longer links to Twitter", %{conn: conn} do
      conn = post(conn, ~p"/new_registration", user: valid_attrs())
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
    # marks its PIN form with a registration context for this. The greeting
    # itself now arrives one page later: the PIN routes them through the
    # one-time welcome page (which greets them in its own hero), and the toast
    # follows them onto the profile the welcome page hands them to — where the
    # checklist it points at actually lives.
    test "the first PIN login after sign-up greets the newcomer", %{conn: conn} do
      conn = post(conn, ~p"/new_registration", user: valid_attrs())
      body = html_response(conn, 200)
      assert body =~ ~s(name="session[context]")
      pin = sent_pin()

      conn =
        submit_with_csrf(conn, ~p"/login", %{
          "session" => %{"pin" => pin, "context" => "registration"}
        })

      # No toast on the welcome page itself: it would talk about a profile the
      # member has not reached yet.
      assert redirected_to(conn) == ~p"/system/welcome"
      refute Phoenix.Flash.get(conn.assigns.flash, :info)

      conn = post(conn, ~p"/system/welcome", %{"skip" => "1"})

      # Greeted by first name, not the anonymous "Welcome to vutuv!", and
      # gently pointed at the two profile steps the checklist will show.
      assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
               "Welcome to vutuv, Newcomer! A photo and a short tagline make your profile complete."
    end
  end

  # The sign-up form must never become an account-enumeration oracle: anyone
  # could otherwise probe an address and read "has already been taken" to learn
  # it belongs to a member. Registering with a known address therefore returns
  # the identical screen a fresh sign-up gets, and the only signal goes to the
  # address owner's own inbox.
  describe "POST /new_registration with an address that already exists" do
    @taken_attrs %{
      "emails" => %{"0" => %{"value" => "taken@example.com"}},
      "first_name" => "Mallory",
      "tag_list" => "Phishing Probing Poking"
    }

    setup %{conn: conn} do
      {:ok, owner} =
        Vutuv.Accounts.register_user(conn, %{
          "emails" => %{"0" => %{"value" => "taken@example.com"}},
          "first_name" => "Owner",
          "tag_list" => registration_tags()
        })

      %{owner: owner}
    end

    test "returns the same PIN screen as a fresh sign-up, with no 'taken' hint", %{conn: conn} do
      conn = post(conn, ~p"/new_registration", user: @taken_attrs)

      # The 200 + PIN-entry confirmation page a real sign-up renders (see the
      # "POST /new_registration" tests above), not the 422 error form.
      body = html_response(conn, 200)
      assert body =~ "INBOX"
      assert body =~ ~s(name="session[pin]")

      # The inline error that used to confirm the address exists is gone.
      refute body =~ "already been taken"
    end

    test "mails the owner a notice with a login link, never a PIN", %{conn: conn} do
      post(conn, ~p"/new_registration", user: @taken_attrs)

      assert_received {:email, email}
      assert {_name, "taken@example.com"} = hd(email.to)
      assert email.subject =~ "Someone tried to register"
      # A way back in for the real owner...
      assert email.text_body =~ "/login"
      # ...but no credential anyone else could use.
      refute email.text_body =~ ~r/\b\d{6}\b/
    end

    test "creates no second account for the address", %{conn: conn} do
      post(conn, ~p"/new_registration", user: @taken_attrs)

      count =
        Repo.one(
          from(e in Vutuv.Accounts.Email, where: e.value == "taken@example.com", select: count())
        )

      assert count == 1
    end

    # Only the address-exists signal is masked. A genuine input error (here no
    # name, so no profile handle can be derived) must still fail the form, and
    # it does so identically whether or not the address exists, so it leaks
    # nothing either.
    test "a real validation error still re-renders the form", %{conn: conn} do
      conn =
        post(conn, ~p"/new_registration",
          user: %{"emails" => %{"0" => %{"value" => "taken@example.com"}}}
        )

      assert conn.status == 422
      refute conn.resp_body =~ "already been taken"
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

  # True when the <input type="radio" name=name value=value> in `html` is
  # checked, regardless of attribute order.
  defp radio_checked?(html, name, value) do
    regex =
      ~r/<input(?=[^>]*\btype="radio")(?=[^>]*\bname="#{Regex.escape(name)}")(?=[^>]*\bvalue="#{Regex.escape(value)}")[^>]*>/

    case Regex.run(regex, html) do
      [tag] -> tag =~ "checked"
      _ -> false
    end
  end

  # Fresh, per-call-unique tag names: an async test file must never insert a
  # tag name/slug another async file also mints — the sandboxed unique-index
  # locks would convoy and deadlock (Postgres 40P01).
  defp registration_tags do
    n = System.unique_integer([:positive])
    "Elixir#{n} Cooking#{n} Origami#{n}"
  end

  defp valid_attrs do
    %{
      "emails" => %{"0" => %{"value" => "newcomer@example.com"}},
      "first_name" => "Newcomer",
      "tag_list" => registration_tags()
    }
  end

  defp user_by_email(value) do
    Vutuv.Repo.one(
      from(u in Vutuv.Accounts.User,
        join: e in assoc(u, :emails),
        where: e.value == ^value
      )
    )
  end

  # Stores the vutuv.de legal text for a page, from the same frozen snapshot
  # the established-install seed migration reads (fresh DBs like this test DB
  # deliberately get no rows, so each test seeds what it asserts).
  defp seed_legal!(slug) do
    body =
      :vutuv
      |> Application.app_dir("priv/repo/seed_data/legal/#{slug}.md")
      |> File.read!()

    {:ok, _page} = Vutuv.Legal.upsert_page(slug, %{body: body})
  end
end
