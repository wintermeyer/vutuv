defmodule VutuvWeb.AgentDocsDriftTest do
  @moduledoc """
  The anti-drift contract for the agent formats (`VutuvWeb.AgentDocs`): every
  public fact a page's HTML shows must also appear in its Markdown, text and
  JSON documents. When this fails you changed a public page (or a doc
  builder) without updating the other side — keep `show.html.heex` (etc.)
  and the `VutuvWeb.AgentDocs.*Doc` builders in sync.
  """

  use VutuvWeb.ConnCase, async: true

  import Vutuv.PostsHelpers

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

    insert(:email, user: user, public?: true, value: "greta.public@example.com")
    insert(:work_experience, user: user, title: "Bridge Engineer", organization: "Span AG")
    insert(:url, user: user, value: "http://bridges.example.org/", description: "Bridge blog")
    insert(:phone_number, user: user, value: "+49 30 5550100", number_type: "mobile")
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
      json: get(build_conn(), path <> ".json").resp_body
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
      # skills
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
    assert body =~ "TEL;TYPE=mobile:+49 30 5550100"
    assert body =~ "EMAIL:greta.public@example.com"
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
end
