defmodule VutuvWeb.AgentDocsDriftTest do
  @moduledoc """
  The anti-drift contract for the agent formats (`VutuvWeb.AgentDocs`): every
  public fact a page's HTML shows must also appear in its Markdown, text,
  JSON and XML documents. When this fails you changed a public page (or a doc
  builder) without updating the other side — keep `show.html.heex` (etc.)
  and the `VutuvWeb.AgentDocs.*Doc` builders in sync.
  """

  use VutuvWeb.ConnCase, async: true

  import Vutuv.PostsHelpers

  alias VutuvWeb.AgentDocs.ProfileDoc
  alias VutuvWeb.AgentDocs.SectionDocs

  setup do
    user =
      insert_activated_user(
        username: "drift_tester",
        first_name: "Greta",
        last_name: "Gradient",
        headline: "Builds bridges between humans and agents",
        gender: "female",
        birthdate: ~D[1991-04-23],
        employment_status: "looking",
        # Opt the availability badge + salary expectation public so they stay in
        # the anonymous agent docs the drift test checks (issue #928: only an
        # "everyone" visibility does).
        employment_status_visibility: "everyone",
        desired_salary_min: 60_000,
        desired_salary_currency: "EUR",
        desired_salary_period: "year",
        desired_salary_visibility: "everyone"
      )

    insert(:email,
      user: user,
      public?: true,
      value: "greta.public@example.com",
      email_type: "Work"
    )

    insert(:work_experience, user: user, title: "Bridge Engineer", organization: "Span AG")

    # A volunteer entry (issue #840): the HTML pages show its category heading,
    # the docs carry the kind — the "volunteer" fact below keeps them in sync.
    # Closed-ended, so it never becomes the header job (the vCard's TITLE/ORG
    # assertions pin Span AG).
    insert(:work_experience,
      user: user,
      title: "River Guardian",
      organization: "Water Watch",
      kind: "volunteer",
      start_month: 2,
      start_year: 2016,
      end_month: 6,
      end_year: 2019
    )

    insert(:education,
      user: user,
      school: "Bridge University",
      degree: "MSc Structures",
      field_of_study: "Structural Engineering",
      description: "Thesis on load distribution"
    )

    # An apprenticeship entry (issue #849): the HTML pages show its category
    # heading, the docs carry the kind — asserted per-format below.
    insert(:education,
      user: user,
      school: "Handwerkskammer Brückenstadt",
      degree: "Gesellenbrief",
      field_of_study: nil,
      description: nil,
      kind: "apprenticeship",
      start_year: 2008,
      end_year: 2011
    )

    insert(:language, user: user, language_code: "fr", proficiency: "native")

    # A certificate (issue #859): its name, issuer and verification URL appear
    # in every format — asserted below.
    insert(:qualification,
      user: user,
      name: "Chartered Structural Engineer",
      kind: "certification",
      # A single-token issuer: the 80-column plain-text renderer hard-wraps on
      # word boundaries, so a long multi-word value would straddle a line break
      # and stop being a contiguous substring (true of any long value in txt).
      issuer: "IStructE",
      awarded_year: 2016,
      credential_id: "MIStructE-42",
      url: "http://istructe.example.org/verify/42"
    )

    insert(:url, user: user, value: "http://bridges.example.org/", description: "Bridge blog")
    insert(:phone_number, user: user, value: "+49 30 5550100", number_type: "Cell")
    insert(:address, user: user, description: "Office", city: "Berlin", zip_code: "10115")
    insert(:social_media_account, user: user, provider: "GitHub", value: "gretagradient")

    tag = insert(:tag, name: "Bridgebuilding", slug: "bridgebuilding")
    insert(:user_tag, user: user, tag: tag)

    follower = insert_activated_user(first_name: "Fanny", last_name: "Follower")
    follow!(follower, user)

    post = create_post!(user, %{"body" => "Suspension bridges are underrated."})

    %{user: user, tag: tag, follower: follower, post: post}
  end

  defp formats_for(path) do
    %{
      html: get(build_conn(), path) |> html_response(200),
      md: get(build_conn(), path <> ".md").resp_body,
      txt: get(build_conn(), path <> ".txt").resp_body,
      json: get(build_conn(), path <> ".json").resp_body,
      xml: get(build_conn(), path <> ".xml").resp_body
    }
  end

  defp assert_fact_everywhere(rendered, fact) do
    for {format, body} <- rendered do
      assert String.downcase(body) =~ String.downcase(fact),
             "#{inspect(fact)} is missing from the #{format} version — " <>
               "HTML page and agent docs have drifted apart (see VutuvWeb.AgentDocs)"
    end
  end

  test "profile: every public fact appears in HTML, Markdown, text and JSON", %{user: user} do
    rendered = formats_for("/drift_tester")

    facts = [
      # identity card
      "Greta Gradient",
      "bridges between humans and agents",
      # experience
      "Bridge Engineer",
      "Span AG",
      # the volunteer entry and its category (issue #840): HTML shows the
      # "Volunteering & hobbies" heading, md/txt the "[Volunteering & hobbies]"
      # note, json/xml the kind field — the case-insensitive "volunteer" is the
      # common substring of all of them
      "River Guardian",
      "Water Watch",
      "volunteer",
      # education
      "Bridge University",
      "MSc Structures",
      # the apprenticeship entry (issue #849); its category is asserted
      # per-format below (no single substring covers HTML label + raw kind)
      "Handwerkskammer Brückenstadt",
      "Gesellenbrief",
      # tags
      "Bridgebuilding",
      # languages (issue #865): the localized name and the proficiency both
      # appear in every format (HTML badge "Native", md/txt "French: Native",
      # JSON/XML the raw "native" proficiency)
      "French",
      "native",
      # qualifications (issue #859): the credential name and its issuer appear
      # in every format (the profile card's meta line, md/txt, JSON/XML)
      "Chartered Structural Engineer",
      "IStructE",
      # links / contact / social / phone / address
      "bridges.example.org",
      "greta.public@example.com",
      "github.com/gretagradient",
      "+49 30 5550100",
      "Berlin",
      # general info
      "female",
      # posts
      "Suspension bridges are underrated."
    ]

    for fact <- facts, do: assert_fact_everywhere(rendered, fact)

    # The education category (issue #849): the HTML page shows the group
    # heading, md/txt mark the entry line, JSON/XML carry the raw kind.
    assert rendered.html =~ "Vocational Training"
    assert rendered.md =~ "[Vocational Training]"
    assert rendered.txt =~ "[Vocational Training]"

    assert Enum.any?(
             Jason.decode!(rendered.json)["educations"],
             &(&1["kind"] == "apprenticeship")
           )

    assert rendered.xml =~ "<kind>apprenticeship</kind>"

    # The employment status (issue #870): the HTML badge and the md/txt fact
    # line show the human label, JSON/XML carry the raw machine value.
    assert rendered.html =~ "Looking for a job"
    assert rendered.md =~ "Employment status: Looking for a job"
    assert rendered.txt =~ "Employment status: Looking for a job"
    assert Jason.decode!(rendered.json)["employment_status"] == "looking"
    assert rendered.xml =~ "<employment_status>looking</employment_status>"

    # The salary expectation (issue #928): the HTML profile line and the md/txt
    # fact line show the "… per period" summary, JSON/XML carry the structured
    # {min, currency, period}.
    assert rendered.html =~ "Salary expectation"
    assert rendered.md =~ "Salary expectation"
    assert rendered.txt =~ "Salary expectation"
    salary = Jason.decode!(rendered.json)["desired_salary"]
    assert salary["min"] == 60_000
    assert salary["currency"] == "EUR"
    assert salary["period"] == "year"
    assert rendered.xml =~ "<desired_salary>"
    assert rendered.xml =~ "<min>60000</min>"

    # The counters: HTML renders "1 follower", the docs carry the number.
    assert rendered.html =~ "follower"
    assert Jason.decode!(rendered.json)["counts"]["followers"] == 1
    assert rendered.md =~ "Followers: 1"
    assert rendered.txt =~ "Followers: 1"

    # The age, derived from the birthday in Berlin time, is an extra field in
    # every machine format and reads naturally in the HTML.
    age = VutuvWeb.UserHelpers.age(user)
    assert rendered.html =~ "#{age} years old"
    assert rendered.md =~ "Age: #{age}"
    assert rendered.txt =~ "Age: #{age}"
    assert Jason.decode!(rendered.json)["age"] == age
    assert rendered.xml =~ "<age>#{age}</age>"

    # The handle is surfaced as an explicit field in the agent formats, not only
    # embedded inside the profile URL (Markdown frontmatter + text footer carry
    # it; JSON/XML serialize it). The HTML carries it in the profile URLs.
    assert rendered.md =~ ~s(username: "drift_tester")
    assert rendered.txt =~ "username: drift_tester"
    assert Jason.decode!(rendered.json)["username"] == "drift_tester"
    assert rendered.xml =~ "<username>drift_tester</username>"
    assert rendered.html =~ "drift_tester"
  end

  test "profile: an excluded signed-in viewer gets the reduced job-search view (issue #938)",
       %{user: user} do
    # The anonymous formats above render the public "everyone" view unchanged —
    # the exclusion list only ever narrows the SIGNED-IN audience (the token
    # /api/2.0 read passes the viewer). Prove both an excluded domain and an
    # excluded member lose employment status + salary, while a stranger keeps
    # them (the base "everyone" gate).
    domain_viewer = insert_activated_user(username: "domain_spy")
    insert(:email, user: domain_viewer, value: "spy@rival.example")
    insert(:viewer_exclusion, user: user, domain: "rival.example")

    member_viewer = insert_activated_user(username: "the_boss")
    insert(:viewer_exclusion, user: user, excluded_user: member_viewer, domain: nil)

    stranger = insert_activated_user(username: "a_stranger")

    for excluded <- [domain_viewer, member_viewer] do
      doc = ProfileDoc.build(user, viewer: excluded)
      assert doc.employment_status == nil
      assert doc.desired_salary == nil
    end

    seen = ProfileDoc.build(user, viewer: stranger)
    assert seen.employment_status == "looking"
    assert seen.desired_salary.min == 60_000
  end

  test "profile: an honor tag is marked as such in every format", %{user: user} do
    honor = insert(:tag, name: "Vutuvdeveloper", slug: "vutuvdeveloper", honor?: true)
    insert(:user_tag, user: user, tag: honor)

    rendered = formats_for("/drift_tester")

    # The tag name rides along in every format like any tag.
    assert_fact_everywhere(rendered, "Vutuvdeveloper")

    # And every format marks it an honor tag rather than counting endorsements —
    # it is an authoritative badge, not a peer vouch.
    assert rendered.md =~ "honor tag"
    assert rendered.txt =~ "honor tag"
    assert rendered.html =~ "Honor tag"

    tag_json =
      Jason.decode!(rendered.json)["tags"]
      |> Enum.find(&(&1["name"] == "Vutuvdeveloper"))

    assert tag_json["honor"] == true
    assert rendered.xml =~ "<honor>true</honor>"
  end

  test "profile vCard carries the same contact facts", %{user: _user} do
    body = get(build_conn(), "/drift_tester.vcf").resp_body

    assert body =~ "FN:Greta Gradient"
    assert body =~ "ORG:Span AG"
    assert body =~ "TITLE:Bridge Engineer"
    assert body =~ "TEL;TYPE=Cell:+49 30 5550100"
    assert body =~ "EMAIL;TYPE=Work:greta.public@example.com"
    assert body =~ "Berlin"
    assert body =~ "URL:"
  end

  test "post permalink: body, author, replies and engagement in every format", %{post: post} do
    replier = insert_activated_user(first_name: "Resa", last_name: "Reply")
    {:ok, _reply} = Vutuv.Posts.create_reply(replier, post, %{"body" => "Agreed, very sturdy."})

    # The HTML action bar shows like/repost/bookmark counts to every visitor,
    # so the agent formats must carry them too.
    fan = insert_activated_user(first_name: "Fan", last_name: "Fervent")
    :ok = Vutuv.Posts.like_post(fan, post)
    :ok = Vutuv.Posts.repost_post(fan, post)
    :ok = Vutuv.Posts.bookmark_post(fan, post)

    rendered = formats_for("/drift_tester/posts/#{post.id}")

    for fact <- [
          "Greta Gradient",
          "Suspension bridges are underrated.",
          "Resa Reply",
          "Agreed, very sturdy."
        ],
        do: assert_fact_everywhere(rendered, fact)

    doc = Jason.decode!(rendered.json)
    assert doc["type"] == "post"
    assert doc["reply_count"] == 1
    assert doc["like_count"] == 1
    assert doc["repost_count"] == 1
    assert doc["bookmark_count"] == 1

    assert rendered.md =~ "Likes: 1"
    assert rendered.txt =~ "Likes: 1"
  end

  test "post archive: entries and total in every format", %{post: post} do
    rendered = formats_for("/drift_tester/posts")

    for fact <- ["Greta Gradient", "Suspension bridges are underrated."],
        do: assert_fact_everywhere(rendered, fact)

    assert Jason.decode!(rendered.json)["total"] == 1

    # The year-scoped archive works with extensions too.
    year = post.published_on.year
    conn = get(build_conn(), "/drift_tester/posts/#{year}.md")
    assert conn.status == 200
    assert conn.resp_body =~ "Suspension bridges"
  end

  test "a restricted post has no agent documents (anonymous view only)", %{user: user} do
    restricted =
      create_post!(user, %{
        "body" => "Members only musings",
        "denials" => [%{"wildcard" => "non_followers"}]
      })

    assert get(build_conn(), "/drift_tester/posts/#{restricted.id}.md").status == 404
    assert get(build_conn(), "/drift_tester/posts/#{restricted.id}.json").status == 404
  end

  test "the canonical-casing redirect keeps the extension", %{post: post} do
    upper = String.upcase(post.id)
    conn = get(build_conn(), "/drift_tester/posts/#{upper}.md")
    assert redirected_to(conn) == "/drift_tester/posts/#{post.id}.md"
  end

  test "the canonical-casing redirect keeps the ?lang= query too", %{post: post} do
    upper = String.upcase(post.id)
    conn = get(build_conn(), "/drift_tester/posts/#{upper}.md?lang=de")
    assert redirected_to(conn) == "/drift_tester/posts/#{post.id}.md?lang=de"
  end

  test "reply_count reflects the replies the anonymous doc actually lists", %{post: post} do
    visible = insert_activated_user(first_name: "Vee", last_name: "Visible")
    {:ok, _} = Vutuv.Posts.create_reply(visible, post, %{"body" => "Sound point."})

    hidden = insert_activated_user(first_name: "Han", last_name: "Hidden")
    {:ok, frozen} = Vutuv.Posts.create_reply(hidden, post, %{"body" => "Secret reply."})

    # A reply can no longer be restricted apart from its parent (issue #774);
    # the only way one is hidden is a moderation freeze.
    frozen
    |> Ecto.Changeset.change(frozen_at: NaiveDateTime.utc_now(:second))
    |> Vutuv.Repo.update!()

    doc = Jason.decode!(get(build_conn(), "/drift_tester/posts/#{post.id}.json").resp_body)

    # The frozen reply is neither listed nor counted in the anonymous doc.
    assert doc["reply_count"] == 1
    assert length(doc["replies"]) == 1
    refute get(build_conn(), "/drift_tester/posts/#{post.id}.txt").resp_body =~ "Secret reply"
  end

  test "follower and following lists in every format", %{user: user, follower: follower} do
    follow!(user, follower)

    # The listed member's tags ride along in every format, like their name. The
    # HTML rows show them (via card_list), so the docs must carry them too.
    insert(:user_tag,
      user: follower,
      tag: insert(:tag, name: "Trailblazing", slug: "trailblazing")
    )

    rendered = formats_for("/drift_tester/followers")
    assert_fact_everywhere(rendered, "Fanny Follower")
    assert_fact_everywhere(rendered, "Trailblazing")
    assert Jason.decode!(rendered.json)["total"] == 1

    rendered = formats_for("/drift_tester/following")
    assert_fact_everywhere(rendered, "Fanny Follower")
    assert_fact_everywhere(rendered, "Trailblazing")
    assert Jason.decode!(rendered.json)["type"] == "following"
  end

  test "tag page: description and most endorsed members in every format", %{tag: tag} do
    tag
    |> Ecto.Changeset.change(description: "The art of connecting shores")
    |> Repo.update!()

    rendered = formats_for("/tags/bridgebuilding")

    for fact <- ["Bridgebuilding", "connecting shores", "Greta Gradient"],
        do: assert_fact_everywhere(rendered, fact)
  end

  test "most followed listing in every format" do
    rendered = formats_for("/listings/most_followed_users")
    assert_fact_everywhere(rendered, "Greta Gradient")
    # Each listed member's tags ride along in every format, like their name.
    assert_fact_everywhere(rendered, "Bridgebuilding")
    assert Jason.decode!(rendered.json)["type"] == "listing"
  end

  test "member directory index in every format" do
    rendered = formats_for("/system/members")

    # Greta Gradient sits under G, Fanny Follower under F — every format
    # must link both letter pages.
    assert_fact_everywhere(rendered, "/system/members/g")
    assert_fact_everywhere(rendered, "/system/members/f")
    assert Jason.decode!(rendered.json)["type"] == "directory"
  end

  test "member directory letter page in every format" do
    rendered = formats_for("/system/members/g")

    assert_fact_everywhere(rendered, "Greta Gradient")
    # Each listed member's tags ride along in every format, like their name.
    assert_fact_everywhere(rendered, "Bridgebuilding")
    assert Jason.decode!(rendered.json)["type"] == "listing"
  end

  test "every profile section page serves its facts in all formats" do
    facts = %{
      work_experiences: ["Bridge Engineer", "Span AG", "Building things"],
      educations: [
        "Bridge University",
        "MSc Structures",
        "Structural Engineering",
        "Thesis on load distribution"
      ],
      languages: ["French", "native"],
      qualifications: ["Chartered Structural Engineer", "IStructE"],
      links: ["bridges.example.org", "Bridge blog"],
      social_media_accounts: ["github.com/gretagradient"],
      addresses: ["Berlin", "10115"],
      phone_numbers: ["+49 30 5550100"],
      emails: ["greta.public@example.com"],
      tags: ["Bridgebuilding"]
    }

    # The loop runs over the SectionDocs registry itself, so a new section
    # without a facts entry here fails loudly instead of going untested.
    for section <- SectionDocs.sections() do
      rendered = formats_for("/drift_tester/#{section}")
      for fact <- Map.fetch!(facts, section), do: assert_fact_everywhere(rendered, fact)

      doc = Jason.decode!(rendered.json)
      assert doc["type"] == Atom.to_string(section)
      assert doc["total"] == length(doc["entries"])
      assert doc["user"]["username"] == "drift_tester"
    end
  end

  test "section docs are noindexed like their HTML pages (the NoIndex pipeline)" do
    conn = get(build_conn(), "/drift_tester/work_experiences.md")

    assert conn.status == 200
    assert get_resp_header(conn, "content-signal") == ["ai-train=no, search=no, ai-input=no"]
    # The page-level restriction covers both axes: out of search results
    # and out of AI corpora, whatever the member's own settings say.
    assert get_resp_header(conn, "x-robots-tag") == ["noindex, noai, noimageai"]
  end

  test "a single section entry page serves all formats", %{user: user} do
    work =
      Repo.one!(
        from(w in Ecto.assoc(user, :work_experiences), where: w.title == "Bridge Engineer")
      )

    rendered = formats_for("/drift_tester/work_experiences/#{work.slug}")

    for fact <- ["Bridge Engineer", "Span AG", "Building things"],
        do: assert_fact_everywhere(rendered, fact)

    assert Jason.decode!(rendered.json)["type"] == "work_experience"

    edu =
      Repo.one!(from(e in Ecto.assoc(user, :educations), where: e.school == "Bridge University"))

    rendered = formats_for("/drift_tester/educations/#{edu.id}")

    for fact <- ["Bridge University", "Structural Engineering", "Thesis on load distribution"],
        do: assert_fact_everywhere(rendered, fact)

    rendered = formats_for("/drift_tester/languages/fr")
    assert_fact_everywhere(rendered, "French")
    assert Jason.decode!(rendered.json)["type"] == "language"

    qualification = Repo.one!(Ecto.assoc(user, :qualifications))
    rendered = formats_for("/drift_tester/qualifications/#{qualification.id}")
    assert_fact_everywhere(rendered, "Chartered Structural Engineer")
    assert Jason.decode!(rendered.json)["type"] == "qualification"

    [url] = Repo.all(Ecto.assoc(user, :urls))
    rendered = formats_for("/drift_tester/links/#{url.id}")
    assert_fact_everywhere(rendered, "bridges.example.org")

    rendered = formats_for("/drift_tester/tags/bridgebuilding")
    assert_fact_everywhere(rendered, "Bridgebuilding")
    assert Jason.decode!(rendered.json)["type"] == "user_tag"
  end

  test "a private email never reaches the agent formats", %{user: user} do
    private = insert(:email, user: user, public?: false, value: "greta.secret@example.com")

    refute get(build_conn(), "/drift_tester/emails.md").resp_body =~ "greta.secret"
    refute get(build_conn(), "/drift_tester/emails.json").resp_body =~ "greta.secret"
    assert get(build_conn(), "/drift_tester/emails/#{private.id}.md").status == 404

    public = Repo.one!(from(e in Ecto.assoc(user, :emails), where: e.public?))
    assert get(build_conn(), "/drift_tester/emails/#{public.id}.md").resp_body =~ "greta.public"
  end

  test "email entries carry their Work/Personal/Other type in every format" do
    doc = Jason.decode!(get(build_conn(), "/drift_tester/emails.json").resp_body)

    assert [%{"type" => "Work", "value" => "greta.public@example.com"}] = doc["entries"]

    assert get(build_conn(), "/drift_tester/emails.md").resp_body =~
             "Work: <greta.public@example.com>"

    assert get(build_conn(), "/drift_tester/emails.txt").resp_body =~
             "Work: greta.public@example.com"

    # The profile doc and vCard carry the same typed address.
    profile = Jason.decode!(get(build_conn(), "/drift_tester.json").resp_body)

    assert Enum.any?(
             profile["emails"],
             &(&1["type"] == "Work" and &1["value"] == "greta.public@example.com")
           )

    assert get(build_conn(), "/drift_tester.vcf").resp_body =~
             "EMAIL;TYPE=Work:greta.public@example.com"
  end

  test "tag endorser list in every format", %{user: user, tag: tag, follower: follower} do
    [user_tag] = Repo.all(from(ut in Vutuv.Tags.UserTag, where: ut.user_id == ^user.id))
    endorsement = insert(:user_tag_endorsement, user_tag: user_tag, user: follower)

    rendered = formats_for("/drift_tester/tags/#{tag.slug}/endorsers")
    assert_fact_everywhere(rendered, "Fanny Follower")

    doc = Jason.decode!(rendered.json)
    assert doc["type"] == "tag_endorsers"
    assert doc["total"] == 1
    # The list names the tag it belongs to.
    assert_fact_everywhere(rendered, "Bridgebuilding")

    # Each row carries when the endorsement was cast. The date (YYYY-MM-DD)
    # appears in every format: the HTML <time> fallback, the md/txt "(endorsed
    # …)" suffix, and the ISO8601 endorsed_at in JSON/XML all contain it.
    date = Calendar.strftime(endorsement.inserted_at, "%Y-%m-%d")
    assert_fact_everywhere(rendered, date)
    assert [%{"endorsed_at" => endorsed_at}] = doc["people"]
    assert is_binary(endorsed_at)
  end

  test "the tag endorser list is noindexed like the other per-user people lists", %{tag: tag} do
    conn = get(build_conn(), "/drift_tester/tags/#{tag.slug}/endorsers.md")

    assert conn.status == 200
    assert get_resp_header(conn, "content-signal") == ["ai-train=no, search=no, ai-input=no"]
    assert get_resp_header(conn, "x-robots-tag") == ["noindex, noai, noimageai"]
  end

  test "connections list in every format", %{user: user} do
    buddy = insert_activated_user(first_name: "Conni", last_name: "Connection")
    connect!(user, buddy)

    rendered = formats_for("/drift_tester/connections")
    assert_fact_everywhere(rendered, "Conni Connection")

    doc = Jason.decode!(rendered.json)
    assert doc["type"] == "connections"
    assert doc["total"] == 1
  end

  test "work experiences sort newest first, the ongoing role on top" do
    user = insert_activated_user(username: "sorted_cv")

    insert(:work_experience,
      user: user,
      title: "Old role",
      start_year: 2010,
      end_year: 2015,
      end_month: 6
    )

    insert(:work_experience,
      user: user,
      title: "Middle role",
      start_year: 2016,
      end_year: 2018,
      end_month: 12
    )

    insert(:work_experience, user: user, title: "Current role", start_year: 2020)

    doc = Jason.decode!(get(build_conn(), "/sorted_cv.json").resp_body)

    assert Enum.map(doc["work_experiences"], & &1["title"]) ==
             ["Current role", "Middle role", "Old role"]
  end

  test "tags sort by endorsement count, ties alphabetically" do
    user = insert_activated_user(username: "sorted_skills")
    endorser = insert_activated_user()

    for {name, slug} <- [{"Beta", "beta"}, {"Alpha", "alpha"}, {"Gamma", "gamma"}] do
      insert(:user_tag, user: user, tag: insert(:tag, name: name, slug: slug))
    end

    [gamma] =
      Repo.all(from(u in Vutuv.Tags.UserTag, join: t in assoc(u, :tag), where: t.slug == "gamma"))

    insert(:user_tag_endorsement, user_tag: gamma, user: endorser)

    doc = Jason.decode!(get(build_conn(), "/sorted_skills.json").resp_body)

    assert Enum.map(doc["tags"], & &1["name"]) == ["Gamma", "Alpha", "Beta"]
  end

  test "?lang=de translates the labels, English stays the default" do
    de_txt = get(build_conn(), "/drift_tester.txt?lang=de").resp_body
    assert de_txt =~ "Mitglied seit:"
    assert de_txt =~ "TAGS"

    de_md = get(build_conn(), "/drift_tester.md?lang=de").resp_body
    assert de_md =~ "## Lebenslauf"

    en_txt = get(build_conn(), "/drift_tester.txt").resp_body
    assert en_txt =~ "Member since:"

    # An unknown language falls back to English instead of erroring.
    fallback = get(build_conn(), "/drift_tester.txt?lang=xx").resp_body
    assert fallback =~ "Member since:"
  end

  test "a linked work experience carries its verified organization page in every format" do
    organization = insert(:organization, name: "Linked Verified AG", slug: "linked-verified")
    user = insert_activated_user(username: "link_drift", first_name: "Lena", last_name: "Linker")

    insert(:work_experience,
      user: user,
      organization_page: organization,
      title: "Linked Engineer",
      organization: "free text org"
    )

    # Both the profile and the work-experiences section carry the linked
    # organization's canonical name and URL, in HTML and every agent format.
    for path <- ["/link_drift", "/link_drift/work_experiences"] do
      rendered = formats_for(path)
      assert_fact_everywhere(rendered, "Linked Verified AG")
      assert_fact_everywhere(rendered, "/organizations/linked-verified")
    end
  end

  test "an organization page's People section appears in every format" do
    organization = insert(:organization, name: "People Verified AG", slug: "people-verified")

    member =
      insert_activated_user(first_name: "Petra", last_name: "People", username: "petra_people")

    insert(:work_experience,
      user: member,
      organization_page: organization,
      title: "Staff Engineer",
      end_year: nil
    )

    rendered = formats_for("/organizations/people-verified")
    assert_fact_everywhere(rendered, "Petra People")
    assert_fact_everywhere(rendered, "/petra_people")
  end

  test "an organization's kind (Art) appears in every format" do
    insert(:organization,
      name: "City Hall",
      slug: "city-hall",
      kind: :government
    )

    rendered = formats_for("/organizations/city-hall")
    # A Behörde is not a company: the kind label rides HTML + every agent format.
    assert_fact_everywhere(rendered, "Public authority")
  end

  test "a job posting appears in every format" do
    posting =
      Vutuv.JobsHelpers.publish_job!(nil, %{
        "title" => "Elixir Engineer (m/w/d)",
        "required_tags" => "Elixir, Phoenix"
      })

    rendered = formats_for("/jobs/#{posting.slug}")
    assert_fact_everywhere(rendered, "Elixir Engineer")
    assert_fact_everywhere(rendered, "Köln")
    assert_fact_everywhere(rendered, "Phoenix")
  end
end
