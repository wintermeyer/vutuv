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
  alias VutuvWeb.Fediverse.Docs

  setup do
    user =
      insert_activated_user(
        username: "drift_tester",
        first_name: "Greta",
        last_name: "Gradient",
        # Federating, so the profile's Fediverse card renders and its handle is
        # drift-checked against the agent formats like every other public fact.
        fediverse_followers?: true,
        headline: "Builds bridges between humans and agents",
        # The spoken-name hint (issue #1112): the profile shows it under the
        # name, so every agent format must carry it too — it is worth the most
        # to a reader that says the name out loud.
        name_pronunciation: "[GRAY-ta GRAY-dee-ent]",
        # Set on purpose so the guard below has something to catch: the gender
        # answer is kept for the membership statistic and no agent format may
        # carry it. An earlier incarnation of this very field was published in
        # every one of them.
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
        desired_salary_visibility: "everyone",
        desired_workplace_types: ["hybrid", "remote"]
      )

    insert(:email,
      user: user,
      public?: true,
      value: "greta.public@example.com",
      email_type: "Work"
    )

    # A certificate (issue #859): its name, issuer and verification URL appear
    # in every format — asserted below. The Bridge Engineer job cites it
    # (issue #858), so the "With qualification" line is drift-checked too.
    qualification =
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

    # A published Arbeitszeugnis. Single-token values on purpose, like the
    # qualification above: the 80-column plain-text renderer wraps on word
    # boundaries, so a long multi-word value stops being a contiguous
    # substring. Its AI review is deliberately absent from every format, which
    # the assertion below checks by name.
    insert(:job_reference,
      user: user,
      title: "Zeugnis Spannbau",
      employer: "Spannbau AG",
      kind: "qualified",
      body: "Sie erledigte alle Aufgaben stets zu unserer vollsten Zufriedenheit.",
      public?: true,
      public_consented_at: DateTime.utc_now(:second)
    )

    # A stored proof document on the credential: the thumbnail + download
    # appear in HTML, the structured `document` map in the machine formats.
    # Moderation is off in tests, so it is released immediately.
    doc_src = Path.join(System.tmp_dir!(), "drift_doc_#{System.unique_integer([:positive])}.jpg")
    {:ok, doc_img} = Image.new(300, 200, color: [10, 120, 200])
    {:ok, _} = Image.write(doc_img, doc_src)
    doc_upload = %Plug.Upload{filename: "proof.jpg", path: doc_src, content_type: "image/jpeg"}

    {:ok, doc_meta} = Vutuv.QualificationDocument.store(doc_upload, qualification.id)

    qualification =
      qualification
      |> Ecto.Changeset.change(
        document: "proof.jpg",
        document_fingerprint: doc_meta.fingerprint,
        document_content_type: doc_meta.content_type,
        document_size: doc_meta.size,
        document_moderation: "approved",
        document_consented_at: DateTime.utc_now(:second)
      )
      |> Vutuv.Repo.update!()

    on_exit(fn ->
      File.rm(doc_src)
      Vutuv.QualificationDocument.delete(qualification.id)
    end)

    insert(:work_experience,
      user: user,
      title: "Bridge Engineer",
      organization: "Span AG",
      qualification: qualification
    )

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

    insert(:url, user: user, value: "http://bridges.example.org/", description: "Bridge blog")
    insert(:phone_number, user: user, value: "+49 30 5550100", number_type: "Cell")
    insert(:address, user: user, description: "Office", city: "Berlin", zip_code: "10115")
    insert(:social_media_account, user: user, provider: "GitHub", value: "gretagradient")
    insert(:messenger, user: user, provider: "Telegram", value: "gretachats")

    tag_name = unique_tag_name("Bridgebuilding")
    tag = insert(:tag, name: tag_name, slug: Vutuv.SlugHelpers.tagify(tag_name))
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

  # The other half of the same fix: the doc reads `JobReference.public_scope/0`,
  # the same scope the profile card reads, so an unpublished Zeugnis — or one
  # whose document is still waiting on moderation — must not appear in a
  # document served anonymously.
  test "profile: an unpublished employment reference stays out of every format", %{user: user} do
    insert(:job_reference,
      user: user,
      title: "Zeugnis Geheim",
      employer: "Verschwiegen GmbH",
      kind: "qualified",
      public?: false
    )

    for {format, body} <- formats_for("/drift_tester") do
      refute body =~ "Zeugnis Geheim",
             "an unpublished Zeugnis leaked into the #{format} version"

      refute body =~ "Verschwiegen GmbH",
             "an unpublished Zeugnis's employer leaked into the #{format} version"
    end
  end

  # A vutuv post can be a photograph and nothing else (`posts/post.ex` allows an
  # empty body), and `PostTeaser.line/1` answers "" for it — so the archive
  # entry was blank. The clause for a post from another network solved exactly
  # this and wrote down why (issue #1163); the vutuv clause beside it did not,
  # so the same asymmetry pointed the other way: the HTML archive rendered the
  # photos and every agent format read an entry with no content at all.
  test "archive: a wordless photo post says it carries a picture", %{user: user} do
    # Straight through the factory: `create_post/2` refuses an empty body unless
    # it is handed the images in the same call, and what is under test here is
    # the *rendering* of a post that already exists in that shape.
    post = insert(:post, user: user, body: "")

    insert(:post_image, post: post)

    for {format, body} <- formats_for("/drift_tester/posts"), format in [:md, :txt] do
      assert body =~ "picture",
             "the #{format} archive renders a wordless photo post as an empty line"
    end
  end

  test "profile: every public fact appears in HTML, Markdown, text and JSON",
       %{user: user, tag: tag} do
    rendered = formats_for("/drift_tester")

    facts = [
      # identity card
      "Greta Gradient",
      "bridges between humans and agents",
      # how the name is said out loud (issue #1112)
      "[GRAY-ta GRAY-dee-ent]",
      # experience
      "Bridge Engineer",
      "Span AG",
      # A published employment reference (issue: the card is public on `/:slug`
      # for every viewer, and the profile doc listed twelve sections and not
      # this one — so an agent reading the `.md` reported the member had none,
      # about the strongest credential a German profile carries).
      "Zeugnis Spannbau",
      "Spannbau AG",
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
      tag.name,
      # languages (issue #865): the localized name and the proficiency both
      # appear in every format (HTML badge "Native", md/txt "French: Native",
      # JSON/XML the raw "native" proficiency)
      "French",
      "native",
      # qualifications (issue #859): the credential name and its issuer appear
      # in every format (the profile card's meta line, md/txt, JSON/XML)
      "Chartered Structural Engineer",
      "IStructE",
      # links / contact / social / messengers / phone / address
      "bridges.example.org",
      "greta.public@example.com",
      "github.com/gretagradient",
      # the messenger's handle and its click-to-chat deep link (issue #949)
      "gretachats",
      "t.me/gretachats",
      "+49 30 5550100",
      "Berlin",
      # the Fediverse address: the profile card shows it to a visitor arriving
      # from Mastodon and friends, md/txt as a fact line, JSON/XML structured
      Docs.handle(user),
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

    # The cited credential on a job (issue #858): the HTML page shows the
    # "With qualification" line, md/txt the bracketed note (asserted without
    # the name — the 80-column plain-text renderer may wrap it onto the next
    # line), JSON/XML the nested reference on the work entry.
    assert rendered.html =~ "With qualification"
    assert rendered.md =~ "[With qualification: Chartered Structural Engineer]"
    assert rendered.txt =~ "With qualification:"

    assert Enum.any?(
             Jason.decode!(rendered.json)["work_experiences"],
             &(&1["qualification"]["name"] == "Chartered Structural Engineer")
           )

    assert rendered.xml =~ "<qualification>"

    # The reverse direction (issue #1005): the credential's list rows show how
    # many jobs it earned and that it is in current use (the Bridge Engineer
    # role is ongoing). HTML shows the badges, md/txt the facts, JSON/XML the
    # structured jobs map.
    assert rendered.html =~ "Used for 1 job"
    assert rendered.html =~ "Currently in use"
    assert rendered.md =~ "used for 1 job"
    assert rendered.md =~ "currently in use"
    assert rendered.txt =~ "used for 1 job"

    qualification_json =
      Jason.decode!(rendered.json)["qualifications"]
      |> Enum.find(&(&1["name"] == "Chartered Structural Engineer"))

    assert qualification_json["jobs"]["count"] == 1
    assert qualification_json["jobs"]["in_use"] == true
    assert rendered.xml =~ "<in_use>true</in_use>"

    # The uploaded proof document: the HTML shows the thumbnail, the machine
    # formats the structured document map, md/txt its absolute URL.
    assert rendered.html =~ "data-document-thumb"
    assert qualification_json["document"]["content_type"] == "image/jpeg"
    assert qualification_json["document"]["url"] =~ "/document/"
    assert rendered.xml =~ "<document>"
    assert rendered.md =~ "/document/"
    assert rendered.txt =~ "/document/"

    # The employment status (issue #870): the HTML badge and the md/txt fact
    # line show the human label, JSON/XML carry the raw machine value.
    assert rendered.html =~ "Looking for a job"
    assert rendered.md =~ "Employment status: Looking for a job"
    assert rendered.txt =~ "Employment status: Looking for a job"
    assert Jason.decode!(rendered.json)["employment_status"] == "looking"
    assert rendered.xml =~ "<employment_status>looking</employment_status>"

    # The workplace preference rides the same badge ("... \u00b7 Remote") and the
    # same visibility, and is a fact line / field of its own in the docs.
    assert rendered.html =~ ~s(data-desired-workplace="hybrid remote")
    assert rendered.md =~ "Preferred workplace: Hybrid, Remote"
    assert rendered.txt =~ "Preferred workplace: Hybrid, Remote"
    assert Jason.decode!(rendered.json)["desired_workplace_types"] == ["hybrid", "remote"]
    assert rendered.xml =~ "<desired_workplace_types>"

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
      assert doc.desired_workplace_types == []
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

  test "profile: the pinned post is marked in every format (issue #1110)",
       %{user: user, post: post} do
    {:ok, _} = Vutuv.Posts.pin_to_profile(user, post)

    rendered = formats_for("/drift_tester")

    # The page leads the Posts card with the marked showcase block...
    assert rendered.html =~ ~s(data-pinned-post="#{post.id}")
    assert rendered.html =~ "data-pinned-banner"
    assert rendered.html =~ "Pinned post"

    # ...md/txt mark the same entry inline, JSON/XML carry the flag.
    assert rendered.md =~ "(pinned post)"
    assert rendered.txt =~ "(pinned post)"

    posts_json = Jason.decode!(rendered.json)["posts"]
    assert [%{"pinned" => true}] = posts_json
    assert rendered.xml =~ "<pinned>true</pinned>"

    # Listed once in every format: the pin replaces the timeline entry, it does
    # not double it (the page drops it from the list below the block).
    assert length(:binary.matches(rendered.html, "Suspension bridges are underrated.")) == 1
    assert length(:binary.matches(rendered.md, "Suspension bridges are underrated.")) == 1
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
    # The online messenger (issue #949) rides as an IMPP line with its deep link.
    assert body =~ "IMPP;TYPE=telegram:https://t.me/gretachats"
    # How the name is said (issue #1112): vCard 3.0 has no standard property for
    # a free-text hint, so it rides as an X- extension right below FN.
    assert body =~ "X-PHONETIC-NAME:[GRAY-ta GRAY-dee-ent]"
  end

  test "every format says which part of the name is which" do
    user =
      insert_activated_user(
        username: "name_parts_tester",
        honorific_prefix: "Dr.",
        first_name: "Ada",
        middle_name: "Augusta",
        last_name: "Lovelace",
        honorific_suffix: "FRS",
        nickname: "Enchantress"
      )

    rendered = formats_for("/#{user.username}")

    # The heading assembles the name and says nothing about the split, so the
    # human-readable formats label each part.
    for {label, value} <- [
          {"Prefix", "Dr."},
          {"First Name", "Ada"},
          {"Middle Name", "Augusta"},
          {"Last Name", "Lovelace"},
          {"Suffix", "FRS"},
          {"Nickname", "Enchantress"}
        ] do
      assert rendered.md =~ "- #{label}: #{value}"
      assert rendered.txt =~ "#{label}: #{value}"
    end

    # The machine formats carry the same parts as their own fields.
    json = Jason.decode!(rendered.json)

    assert json["first_name"] == "Ada"
    assert json["middle_name"] == "Augusta"
    assert json["last_name"] == "Lovelace"
    assert json["nickname"] == "Enchantress"
    assert json["honorific_prefix"] == "Dr."
    assert json["honorific_suffix"] == "FRS"

    assert rendered.xml =~ "<first_name>Ada</first_name>"
    assert rendered.xml =~ "<last_name>Lovelace</last_name>"

    # The vCard's structured N is last;first;middle;prefix;suffix; the nickname
    # has no room there, so it rides in its own RFC 2426 property.
    vcard = get(build_conn(), "/#{user.username}.vcf").resp_body

    assert vcard =~ "N:Lovelace;Ada;Augusta;Dr.;FRS"
    assert vcard =~ "NICKNAME:Enchantress"

    # The labels are gettext, and vutuv is a German site — the whole point of
    # the lines is lost if they only name the parts in English.
    german = get(build_conn(), "/#{user.username}.txt?lang=de").resp_body

    assert german =~ "Vorname: Ada"
    assert german =~ "Nachname: Lovelace"
  end

  test "a member with only the two usual name parts gets no empty label lines" do
    user = insert_activated_user(username: "two_part_name", first_name: "Ada", last_name: "Byron")

    rendered = formats_for("/#{user.username}")

    assert rendered.txt =~ "First Name: Ada"
    assert rendered.txt =~ "Last Name: Byron"

    for label <- ["Prefix", "Middle Name", "Suffix", "Nickname"] do
      refute rendered.md =~ "- #{label}:"
      refute rendered.txt =~ "#{label}:"
    end

    refute get(build_conn(), "/#{user.username}.vcf").resp_body =~ "NICKNAME"
  end

  test "a member without a pronunciation gets no phonetic line in the vCard" do
    user = insert_activated_user(username: "no_phonetics", first_name: "Plain")

    body = get(build_conn(), "/#{user.username}.vcf").resp_body

    refute body =~ "X-PHONETIC-NAME"
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

    # A favourite from another network (issue #1068): the HTML counts it as a
    # like like any other and breaks it back out — with the account behind it —
    # in the card's "from other networks" panel, so the siblings must carry the
    # folded figure AND the split. Written straight to the table — the inbox
    # rules that put it there are the Fediverse tests' business, this one is
    # about what the formats render.
    Vutuv.Repo.insert!(%Vutuv.Fediverse.Reaction{
      post_id: post.id,
      actor_uri: "https://social.example/users/alice",
      handle: "alice",
      kind: "like",
      received_at: DateTime.utc_now(:second)
    })

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
    # The vutuv like plus the remote favourite: one like count, the way the
    # button shows it.
    assert doc["like_count"] == 2
    assert doc["repost_count"] == 1
    assert doc["bookmark_count"] == 1
    # ...and the panel's breakdown of how much of that came from out there.
    assert doc["fediverse_like_count"] == 1
    assert doc["fediverse_repost_count"] == 0
    assert doc["fediverse_reaction_count"] == 1

    # The HTML names the account and the verb on its chip, so the siblings do
    # too — a reader of the `.md` learns exactly what a reader of the page does.
    assert [%{"handle" => "@alice@social.example", "kind" => "like"} = reaction] =
             doc["fediverse_reactions"]

    assert reaction["url"] == "https://social.example/users/alice"
    assert reaction["network"] == "social.example"

    assert rendered.md =~ "Likes: 2"
    assert rendered.txt =~ "Likes: 2"

    # The HTML page names the members behind those likes (issue #1233), so the
    # siblings carry them as well — the same people, from the same query.
    assert [%{"name" => "Fan Fervent", "username" => fan_handle}] = doc["likers"]
    assert fan_handle == fan.username

    for format <- [rendered.md, rendered.txt], do: assert(format =~ "Fan Fervent")

    for format <- [rendered.md, rendered.txt] do
      assert format =~ "Reactions from other networks: 1"
      assert format =~ "@alice@social.example liked this"
      # The same sentence the panel closes with: the split is part of the
      # counts above, not something to add to them.
      assert format =~ "Already counted in the numbers above."
    end
  end

  test "post permalink: a page's like is named like a member's (issue #1410)", %{post: post} do
    page = insert(:organization, name: "Drift Likering GmbH")
    page_like!(post, page)

    rendered = formats_for("/drift_tester/posts/#{post.id}")

    doc = Jason.decode!(rendered.json)
    assert [liker] = doc["likers"]
    assert liker["name"] == "Drift Likering GmbH"
    assert liker["url"] =~ "/organizations/#{page.slug}"

    for format <- [rendered.md, rendered.txt], do: assert(format =~ "Drift Likering GmbH")
  end

  test "post permalink: a liker who opted out is named in no format, and still counted", %{
    post: post
  } do
    shy =
      insert_activated_user(first_name: "Shy", last_name: "Sympathiser", like_attribution?: false)

    :ok = Vutuv.Posts.like_post(shy, post)

    rendered = formats_for("/drift_tester/posts/#{post.id}")
    doc = Jason.decode!(rendered.json)

    # These documents are the anonymous public view; their reader is never the
    # post's author, so the one exception the HTML page makes — the author
    # keeps seeing a liker who opted out, having been told their name in the
    # notification at the time — deliberately has no counterpart here.
    assert doc["likers"] == []
    assert doc["like_count"] == 1

    for format <- [rendered.md, rendered.txt, rendered.json, rendered.xml],
        do: refute(format =~ "Sympathiser")
  end

  # Issue #1104. The rule these three assert together: an agent format shows
  # exactly what a visitor to the HTML page sees about a photo — its caption
  # and licence always, its camera settings and download link only where the
  # author published them.
  test "post permalink: a photo's caption and the post's licence reach every format", %{
    user: user
  } do
    image = insert(:post_image, user: user, caption: "Lisbon, last morning", alt: "A yellow tram")

    {:ok, post} =
      Vutuv.Posts.create_post(user, %{
        body: "From the trip.",
        image_ids: [image.id],
        license: "cc-by-4.0"
      })

    rendered = formats_for("/drift_tester/posts/#{post.id}")

    for fact <- ["Lisbon, last morning", "CC BY 4.0"], do: assert_fact_everywhere(rendered, fact)

    doc = Jason.decode!(rendered.json)
    assert doc["license"]["spdx"] == "CC-BY-4.0"
    assert doc["license"]["url"] == "https://creativecommons.org/licenses/by/4.0/"
    assert [photo] = doc["images"]
    assert photo["caption"] == "Lisbon, last morning"
    assert photo["alt"] == "A yellow tram"
  end

  test "post permalink: camera settings and the download appear only where the author published them",
       %{user: user} do
    facts = [
      camera: "Canon EOS R6",
      lens: "RF50mm F1.8 STM",
      focal_length: "50",
      aperture: "1.8",
      shutter: "1/200",
      iso: 400
    ]

    shown =
      insert(:post_image, [user: user, show_camera_info: true, download_original: true] ++ facts)

    hidden = insert(:post_image, [user: user] ++ facts)

    {:ok, post} =
      Vutuv.Posts.create_post(user, %{body: "Two photos.", image_ids: [shown.id, hidden.id]})

    rendered = formats_for("/drift_tester/posts/#{post.id}")
    doc = Jason.decode!(rendered.json)
    [published, withheld] = doc["images"]

    assert published["camera"] == "Canon EOS R6"
    assert published["iso"] == 400
    assert published["download_url"] =~ "/post_images/#{shown.token}/original.orig"

    # The withheld photo carries no camera keys at all — not a set of nulls,
    # which would tell a reader the facts exist and are being kept back.
    refute Map.has_key?(withheld, "camera")
    refute Map.has_key?(withheld, "iso")
    assert withheld["download_url"] == nil

    assert rendered.md =~ "Canon EOS R6 · RF50mm F1.8 STM · 50 mm · f/1.8 · 1/200 s · ISO 400"
    assert rendered.txt =~ "Canon EOS R6 · RF50mm F1.8 STM · 50 mm · f/1.8 · 1/200 s · ISO 400"
  end

  test "post permalink: an all-rights-reserved post advertises no reuse", %{user: user} do
    image = insert(:post_image, user: user)
    {:ok, post} = Vutuv.Posts.create_post(user, %{body: "Mine.", image_ids: [image.id]})

    rendered = formats_for("/drift_tester/posts/#{post.id}")
    doc = Jason.decode!(rendered.json)

    assert doc["license"]["id"] == "arr"
    assert doc["license"]["spdx"] == nil
    # The HTML page renders no licence line for the default, so neither may
    # the readable formats — a rights notice on every post trains people to
    # stop reading the one that matters.
    refute rendered.md =~ "Photos:"
    refute rendered.txt =~ "Photos:"
  end

  test "post permalink: a reply from another network reaches every format (issue #1069)", %{
    post: post
  } do
    now = DateTime.utc_now(:second)

    Vutuv.Repo.insert!(%Vutuv.Fediverse.Note{
      post_id: post.id,
      object_uri: "https://social.example/users/alice/statuses/9",
      actor_uri: "https://social.example/users/alice",
      origin_url: "https://social.example/@alice/9",
      handle: "alice",
      display_name: "Alice Anders",
      content_text: "Sturdier than they look.",
      audience: "public",
      received_at: now,
      checked_at: now,
      expires_at: DateTime.add(now, 86_400)
    })

    rendered = formats_for("/drift_tester/posts/#{post.id}")

    for fact <- ["Alice Anders", "Sturdier than they look.", "@alice@social.example"],
        do: assert_fact_everywhere(rendered, fact)

    doc = Jason.decode!(rendered.json)
    assert doc["fediverse_reply_count"] == 1
    assert [entry] = doc["fediverse_replies"]
    assert entry["handle"] == "@alice@social.example"
    assert entry["url"] == "https://social.example/@alice/9"
    # A reply is a reply, whichever world wrote it: the HTML reply button counts
    # this one, so `reply_count` does too. The split stays readable one field
    # down — `fediverse_reply_count` says how much of it came from out there,
    # and `replies` (the vutuv ones) is empty.
    assert doc["reply_count"] == 1
    assert doc["replies"] == []

    assert rendered.md =~ "Replies from other networks: 1"
    assert rendered.txt =~ "Replies from other networks: 1"
  end

  test "a reply sent to the member alone never reaches an agent format (issue #1071)", %{
    post: post
  } do
    now = DateTime.utc_now(:second)

    Vutuv.Repo.insert!(%Vutuv.Fediverse.Note{
      post_id: post.id,
      object_uri: "https://social.example/users/mallory/statuses/1",
      actor_uri: "https://social.example/users/mallory",
      handle: "mallory",
      display_name: "Mallory Private",
      content_text: "This one is between us.",
      audience: "direct",
      received_at: now,
      checked_at: now,
      expires_at: DateTime.add(now, 86_400)
    })

    rendered = formats_for("/drift_tester/posts/#{post.id}")

    for format <- [rendered.md, rendered.txt, rendered.json, rendered.xml] do
      refute format =~ "This one is between us."
      refute format =~ "Mallory Private"
    end

    doc = Jason.decode!(rendered.json)
    assert doc["fediverse_replies"] == []
    # The count a stranger can read must not move either, or it leaks that a
    # private message exists.
    assert doc["fediverse_reply_count"] == 0
  end

  test "post permalink: the whole conversation reaches every format (issue #1006)", %{
    user: user,
    post: post
  } do
    {:ok, focus} = Vutuv.Posts.create_reply(user, post, %{"body" => "The conversation pivot."})
    {:ok, nested} = Vutuv.Posts.create_reply(user, focus, %{"body" => "A deeper drift answer."})

    rendered = formats_for("/drift_tester/posts/#{focus.id}")

    # The HTML permalink shows the whole thread now, root above and the nested
    # answer below — so every agent format must carry both.
    for fact <- ["Suspension bridges are underrated.", "A deeper drift answer."],
        do: assert_fact_everywhere(rendered, fact)

    doc = Jason.decode!(rendered.json)
    assert [root_entry, focus_entry, nested_entry] = doc["thread"]
    assert root_entry["id"] == post.id
    assert root_entry["in_reply_to_id"] == nil
    assert focus_entry["id"] == focus.id
    assert focus_entry["in_reply_to_id"] == post.id
    assert nested_entry["id"] == nested.id
    assert nested_entry["in_reply_to_id"] == focus.id
    refute doc["thread_truncated"]

    # Each entry also carries how deep it hangs, so a reader gets the tree
    # without walking the parent pointers itself.
    assert [0, 1, 2] == Enum.map(doc["thread"], & &1["depth"])

    # And the depth is what the human-readable formats indent by: a heading
    # level per step in Markdown, two spaces per step in plain text.
    author = nested_entry["author"]
    assert rendered.md =~ "##### [#{author}]"
    assert rendered.txt =~ "\n    * #{author} ·"
  end

  # A thread branches, and the branch has to survive into the agent formats the
  # same way it does on the page: depth-first, so a reply follows the post it
  # answers rather than whatever was written last (issue #1027).
  test "post permalink: a branching conversation reaches every format in reading order", %{
    user: user,
    post: post
  } do
    {:ok, alpha} = Vutuv.Posts.create_reply(user, post, %{"body" => "The alpha drift branch."})
    {:ok, beta} = Vutuv.Posts.create_reply(user, post, %{"body" => "The beta drift branch."})
    {:ok, late} = Vutuv.Posts.create_reply(user, alpha, %{"body" => "The late drift answer."})

    rendered = formats_for("/drift_tester/posts/#{late.id}")

    for fact <- ["The alpha drift branch.", "The beta drift branch.", "The late drift answer."],
        do: assert_fact_everywhere(rendered, fact)

    doc = Jason.decode!(rendered.json)

    assert [post.id, alpha.id, late.id, beta.id] == Enum.map(doc["thread"], & &1["id"])
    assert [0, 1, 2, 1] == Enum.map(doc["thread"], & &1["depth"])
  end

  # The HTML marks a link to the author's proven webpage with an emerald ✓ and
  # an accessible label (issue #1246). An icon is invisible to a `.md`/`.json`
  # reader, so the fact has to travel as a sentence and as data.
  test "post permalink: a link to the author's proven webpage reaches every format", %{
    user: user
  } do
    insert(:url,
      user: user,
      value: "https://greta.example/~greta",
      description: "Never the anchor text",
      verification_method: "rel_me",
      verified_at: ~N[2026-08-01 10:00:00]
    )

    post = create_post!(user, %{"body" => "Wrote it up: https://greta.example/~greta"})
    rendered = formats_for("/drift_tester/posts/#{post.id}")

    assert rendered.html =~ "verified-author-link"
    assert rendered.html =~ "Verified webpage of the author (greta.example/~greta)"
    # The author's own words stay the anchor text in every format.
    refute rendered.html =~ "Never the anchor text"

    for format <- [rendered.md, rendered.txt] do
      assert format =~ "Verified webpages of the author linked here:"
      assert format =~ "greta.example/~greta"
    end

    # ...including how far the proof reaches: a rel=me back-link on a sub-page
    # proves that page and nothing else on the host. Asserted on the Markdown
    # sibling alone — the text renderer hard-wraps at 80 columns, so a phrase
    # this long is not a contiguous substring there.
    assert rendered.md =~ "greta.example/~greta (this page only)"

    assert [entry] = Jason.decode!(rendered.json)["verified_author_links"]
    assert entry["address"] == "greta.example/~greta"
    assert entry["url"] == "https://greta.example/~greta"
    assert entry["verified_method"] == "rel_me"
    assert entry["scope"] == "page"

    assert rendered.xml =~ "<scope>page</scope>"
  end

  test "post permalink: an ordinary post says nothing about verified webpages", %{post: post} do
    rendered = formats_for("/drift_tester/posts/#{post.id}")

    refute rendered.html =~ "verified-author-link"
    for format <- [rendered.md, rendered.txt], do: refute(format =~ "Verified webpages")
    assert Jason.decode!(rendered.json)["verified_author_links"] == []
  end

  test "post permalink: a book review's facts reach every format", %{user: user} do
    reviewed =
      create_post!(user, %{
        "body" => "A classic worth rereading.",
        "review" => %{
          "kind" => "book",
          "identifier" => "978-3-16-148410-0",
          "title" => "Refactoring",
          "creator" => "Martin Fowler",
          "year" => "2018",
          "medium" => "audiobook"
        }
      })

    # The edition details are fetched from Open Library after the fact, not
    # typed into the composer — set here the way the fetch sets them.
    reviewed.review
    |> Ecto.Changeset.change(%{pages: 448, publisher: "Addison-Wesley", duration_minutes: 440})
    |> Vutuv.Repo.update!()

    rendered = formats_for("/drift_tester/posts/#{reviewed.id}")

    for fact <- ["Refactoring", "Martin Fowler", "Audiobook", "Addison-Wesley"],
        do: assert_fact_everywhere(rendered, fact)

    # Page count and running time read as sentences for humans and as plain
    # numbers for machines, so they are asserted per audience.
    for {format, body} <- Map.take(rendered, [:html, :md, :txt]) do
      assert body =~ "448 pages (print edition)", "the #{format} version lost the page count"
      assert body =~ "7 h 20 min", "the #{format} version lost the running time"
    end

    # The ISBN is the one fact that renders per audience: readers get it
    # hyphenated the way it is printed on the book (Vutuv.Isbn.format/1),
    # machines the bare canonical digits.
    for {format, body} <- Map.take(rendered, [:html, :md, :txt]),
        do: assert(body =~ "978-3-16-148410-0", "the #{format} version lost the printed ISBN")

    for {format, body} <- Map.take(rendered, [:json, :xml]),
        do: assert(body =~ "9783161484100", "the #{format} version lost the stored ISBN")

    doc = Jason.decode!(rendered.json)
    assert doc["review"]["kind"] == "book"
    assert doc["review"]["identifier"] == "9783161484100"
    assert doc["review"]["year"] == 2018
    assert doc["review"]["medium"] == "audiobook"
    assert doc["review"]["pages"] == 448
    assert doc["review"]["publisher"] == "Addison-Wesley"
    assert doc["review"]["duration_minutes"] == 440
    assert doc["review"]["link"] == "https://www.amazon.de/dp/316148410X"
  end

  test "post archive: entries and total in every format", %{post: post} do
    # No XML document on the unscoped archive: `/:slug/posts.xml` is the
    # natural feed-URL guess, so it 301s to the RSS feed instead (covered in
    # feed_controller_test.exs) — the drift contract here is md/txt/json.
    rendered = formats_for("/drift_tester/posts") |> Map.delete(:xml)

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

  test "tag page: description, endorsed members, open positions and posts in every format",
       %{tag: tag, user: user} do
    tag
    |> Ecto.Changeset.change(description: "The art of connecting shores")
    |> Repo.update!()

    # The tag page's "Offene Stellen" section (#933): a live posting carrying the
    # tag must surface in the HTML page and every agent format.
    Vutuv.JobsHelpers.publish_job!(nil, %{
      "title" => "Bridge Architect (m/w/d)",
      "required_tags" => tag.name
    })

    # "Posts with this tag" (#946): a public post carrying the tag surfaces on
    # the HTML page and in every agent format.
    create_post!(user, %{body: "Spanning the great divide today", tags: tag.name})

    rendered = formats_for("/tags/#{tag.slug}")

    for fact <- [
          tag.name,
          "connecting shores",
          "Greta Gradient",
          "Bridge Architect",
          "Spanning the great divide"
        ],
        do: assert_fact_everywhere(rendered, fact)
  end

  test "most followed listing in every format", %{tag: tag} do
    rendered = formats_for("/listings/most_followed_users")
    assert_fact_everywhere(rendered, "Greta Gradient")
    # Each listed member's tags ride along in every format, like their name.
    assert_fact_everywhere(rendered, tag.name)
    assert Jason.decode!(rendered.json)["type"] == "listing"
  end

  test "member directory index in every format" do
    rendered = formats_for("/system/members")

    # Greta Gradient sits under G, Fanny Follower under F — every format
    # must link both letter pages.
    assert_fact_everywhere(rendered, "/system/members/g")
    assert_fact_everywhere(rendered, "/system/members/f")

    doc = Jason.decode!(rendered.json)
    assert doc["type"] == "directory"

    # The sentence the page states, in every format — and it carries no figure.
    # The whole membership and the Fediverse head count left in 2026-08-13 (the
    # top bar's people pill carries them) and the listed count on 2026-08-28, so
    # no format may reintroduce either as prose.
    assert_fact_everywhere(rendered, "vutuv member")
    refute rendered.html =~ "#{doc["total"]} vutuv member"
    refute Map.has_key?(doc, "members_total")

    # The count survives as **data**, for a reader with no A-Z strip in front of
    # them: `total` plus a per-letter `count`. That asymmetry is the point of
    # having two renderings, not drift between them.
    assert doc["total"] > 0
    assert Enum.any?(doc["letters"], &(&1["count"] > 0))
  end

  test "member directory letter page in every format", %{tag: tag} do
    rendered = formats_for("/system/members/g")

    # The HTML files each member under their last name ("Gradient, Greta")
    # while the docs carry the canonical name, so the shared fact is the name
    # itself rather than one particular order of its parts.
    assert_fact_everywhere(rendered, "Gradient")
    assert_fact_everywhere(rendered, "Greta")
    # Each listed member's tags ride along in every format, like their name.
    assert_fact_everywhere(rendered, tag.name)
    assert Jason.decode!(rendered.json)["type"] == "listing"
  end

  test "every profile section page serves its facts in all formats", %{tag: tag} do
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
      messengers: ["gretachats", "t.me/gretachats"],
      addresses: ["Berlin", "10115"],
      phone_numbers: ["+49 30 5550100"],
      emails: ["greta.public@example.com"],
      tags: [tag.name],
      job_references: ["Zeugnis Spannbau", "Spannbau AG"]
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

  test "the tag list names each tag's endorsers in every format (issue #895)", %{
    user: user,
    tag: tag,
    follower: follower
  } do
    user_tag =
      Repo.one!(
        from(ut in Vutuv.Tags.UserTag, where: ut.user_id == ^user.id and ut.tag_id == ^tag.id)
      )

    insert(:user_tag_endorsement, user_tag: user_tag, user: follower)

    rendered = formats_for("/drift_tester/tags")

    # The HTML rows name the endorsers, so the docs carry the same roster.
    assert_fact_everywhere(rendered, "Fanny Follower")

    entry =
      Jason.decode!(rendered.json)["entries"]
      |> Enum.find(&(&1["name"] == tag.name))

    assert entry["endorsements"] == 1
    assert [%{"name" => "Fanny Follower", "username" => _}] = entry["endorsers"]
  end

  test "section docs are noindexed like their HTML pages (the NoIndex pipeline)" do
    conn = get(build_conn(), "/drift_tester/work_experiences.md")

    assert conn.status == 200
    assert get_resp_header(conn, "content-signal") == ["ai-train=no, search=no, ai-input=no"]
    # The page-level restriction covers both axes: out of search results
    # and out of AI corpora, whatever the member's own settings say.
    assert get_resp_header(conn, "x-robots-tag") == ["noindex, noai, noimageai"]
  end

  test "a single section entry page serves all formats", %{user: user, tag: tag} do
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

    rendered = formats_for("/drift_tester/tags/#{tag.slug}")
    assert_fact_everywhere(rendered, tag.name)
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

  test "the gender never reaches any public format" do
    # The setup member has `gender: "female"`. This field was once a published
    # fact in all four formats plus the profile page; it is now a voluntary
    # answer kept for the membership statistic, and the only thing a reader may
    # notice about it is the greeting in a mail addressed to that member. This
    # asserts the whole vocabulary, not just the stored value, so renaming the
    # label cannot quietly put it back on a public page.
    for path <- ["/drift_tester", "/drift_tester.md", "/drift_tester.txt", "/drift_tester.json"],
        needle <- ["gender", "Gender", "Female", "female", "Weiblich"] do
      refute get(build_conn(), path).resp_body =~ needle,
             "#{needle} must not appear in #{path}"
    end
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
    assert_fact_everywhere(rendered, tag.name)

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

    # Unique suffixes keep the alphabetical tie order (Alpha-* < Beta-*).
    beta = unique_tag_name("Beta")
    alpha = unique_tag_name("Alpha")
    gamma = unique_tag_name("Gamma")

    for name <- [beta, alpha, gamma] do
      insert(:user_tag,
        user: user,
        tag: insert(:tag, name: name, slug: Vutuv.SlugHelpers.tagify(name))
      )
    end

    [gamma_ut] =
      Repo.all(
        from(u in Vutuv.Tags.UserTag,
          join: t in assoc(u, :tag),
          where: t.slug == ^Vutuv.SlugHelpers.tagify(gamma)
        )
      )

    insert(:user_tag_endorsement, user_tag: gamma_ut, user: endorser)

    doc = Jason.decode!(get(build_conn(), "/sorted_skills.json").resp_body)

    assert Enum.map(doc["tags"], & &1["name"]) == [gamma, alpha, beta]
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
    # publish_job! creates real tag rows from required_tags, so the names must
    # be unique across async files (markdown_hashtags_test.exs mints "Elixir").
    phoenix = unique_tag_name("Phoenix")

    posting =
      Vutuv.JobsHelpers.publish_job!(nil, %{
        "title" => "Elixir Engineer (m/w/d)",
        "required_tags" => "#{unique_tag_name("Elixir")}, #{phoenix}"
      })

    rendered = formats_for("/jobs/#{posting.slug}")
    assert_fact_everywhere(rendered, "Elixir Engineer")
    assert_fact_everywhere(rendered, "Köln")
    assert_fact_everywhere(rendered, phoenix)
  end

  test "a remote posting's applicant countries appear in every format" do
    # The HTML detail page used to show nothing at all for a remote posting,
    # so the countries the poster picked existed only in the agent documents
    # (issues #1558/#1559).
    posting =
      Vutuv.JobsHelpers.publish_job!(nil, %{
        "title" => "Remote Elixir Engineer",
        "workplace_type" => "remote",
        "remote_countries" => ["DE", "AT"],
        "required_tags" => unique_tag_name("Elixir")
      })

    rendered = formats_for("/jobs/#{posting.slug}")
    assert_fact_everywhere(rendered, "Germany")
    assert_fact_everywhere(rendered, "Austria")
  end

  test "a region preset is named in every format, not only spelled out" do
    # The HTML chip says "EU" where the poster picked the preset; the agent
    # formats keep all 27 names AND carry the word (issue #1559).
    posting =
      Vutuv.JobsHelpers.publish_job!(nil, %{
        "title" => "EU-wide Elixir Engineer",
        "workplace_type" => "remote",
        "remote_countries" => Vutuv.Countries.region_codes("EU"),
        "required_tags" => unique_tag_name("Elixir")
      })

    rendered = formats_for("/jobs/#{posting.slug}")

    # Not assert_fact_everywhere: "EU" is a substring of the EUR currency the
    # salary line carries, so a bare search would pass without the region.
    assert rendered.html =~ ~r/>\s*EU\s*</
    assert rendered.md =~ "(EU: "
    assert rendered.txt =~ "(EU: "
    assert Jason.decode!(rendered.json)["remote_region"] == "EU"
    assert rendered.xml =~ "<remote_region>EU</remote_region>"

    # The enumeration survives for anything filtering on it.
    for format <- [:md, :txt, :json, :xml], do: assert(rendered[format] =~ "Portugal")
  end

  test "the job board appears in every format" do
    Vutuv.JobsHelpers.publish_job!(nil, %{
      "title" => "Board Tester Role",
      "required_tags" => unique_tag_name("Elixir")
    })

    rendered = formats_for("/jobs")
    assert_fact_everywhere(rendered, "Board Tester Role")
    assert_fact_everywhere(rendered, "Köln")
  end
end
