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

  alias VutuvWeb.AgentDocs.SectionDocs

  setup do
    user =
      insert_activated_user(
        active_slug: "drift_tester",
        first_name: "Greta",
        last_name: "Gradient",
        headline: "Builds bridges between humans and agents",
        gender: "female",
        birthdate: ~D[1991-04-23]
      )

    insert(:email,
      user: user,
      public?: true,
      value: "greta.public@example.com",
      email_type: "Work"
    )

    insert(:work_experience, user: user, title: "Bridge Engineer", organization: "Span AG")
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

  test "profile: every public fact appears in HTML, Markdown, text and JSON" do
    rendered = formats_for("/drift_tester")

    facts = [
      # identity card
      "Greta Gradient",
      "bridges between humans and agents",
      # experience
      "Bridge Engineer",
      "Span AG",
      # tags
      "Bridgebuilding",
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

    # The counters: HTML renders "1 follower", the docs carry the number.
    assert rendered.html =~ "follower"
    assert Jason.decode!(rendered.json)["counts"]["followers"] == 1
    assert rendered.md =~ "Followers: 1"
    assert rendered.txt =~ "Followers: 1"
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

  test "post permalink: body, author and replies in every format", %{post: post} do
    replier = insert_activated_user(first_name: "Resa", last_name: "Reply")
    {:ok, _reply} = Vutuv.Posts.create_reply(replier, post, %{"body" => "Agreed, very sturdy."})

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

    rendered = formats_for("/drift_tester/followers")
    assert_fact_everywhere(rendered, "Fanny Follower")
    assert Jason.decode!(rendered.json)["total"] == 1

    rendered = formats_for("/drift_tester/following")
    assert_fact_everywhere(rendered, "Fanny Follower")
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
    assert Jason.decode!(rendered.json)["type"] == "listing"
  end

  test "every profile section page serves its facts in all formats" do
    facts = %{
      work_experiences: ["Bridge Engineer", "Span AG", "Building things"],
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
      assert doc["user"]["slug"] == "drift_tester"
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
    work = Repo.one!(Ecto.assoc(user, :work_experiences))
    rendered = formats_for("/drift_tester/work_experiences/#{work.slug}")

    for fact <- ["Bridge Engineer", "Span AG", "Building things"],
        do: assert_fact_everywhere(rendered, fact)

    assert Jason.decode!(rendered.json)["type"] == "work_experience"

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
    user = insert_activated_user(active_slug: "sorted_cv")

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
    user = insert_activated_user(active_slug: "sorted_skills")
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
end
