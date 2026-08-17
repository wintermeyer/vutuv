defmodule VutuvWeb.OrganizationPostsWebTest do
  @moduledoc """
  The web surface of posts published in an organization's name (issue #1334):
  the composer on the organization page, the post rendering under the
  organization's own name, and the permalink's scoping. `async: false` because
  the organization helpers flip the global `:verify_organization_domains` flag.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.OrganizationsHelpers

  alias Vutuv.Organizations
  alias Vutuv.Posts

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  describe "the composer on the organization page" do
    test "a publisher writes as the organization and the post appears under its name",
         %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      organization = active_organization_for(owner)
      {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{organization.slug}")

      html =
        view
        |> element("#organization-post-form")
        |> render_submit(%{"body" => "Wir stellen ein."})

      # The post is signed by the organization, never by the member who wrote it.
      assert html =~ "Wir stellen ein."
      assert html =~ organization.name

      [post] = Posts.organization_posts_page(organization, owner).entries
      assert post.organization_id == organization.id
      assert post.acting_user_id == owner.id
    end

    test "an owner without the publisher role gets no composer", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      organization = active_organization_for(owner)

      {:ok, _view, html} = live(conn, ~p"/organizations/#{organization.slug}")

      refute html =~ "organization-post-form"
    end

    test "a visitor sees the published post but no composer", %{conn: conn} do
      owner = insert(:activated_user)
      organization = active_organization_for(owner)
      {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
      {:ok, _post} = Posts.create_organization_post(organization, owner, %{body: "Öffentlich."})

      {:ok, _view, html} = live(conn, ~p"/organizations/#{organization.slug}")

      assert html =~ "Öffentlich."
      refute html =~ "organization-post-form"
    end
  end

  describe "the permalink" do
    setup do
      owner = insert(:activated_user)
      organization = active_organization_for(owner)
      {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
      {:ok, post} = Posts.create_organization_post(organization, owner, %{body: "Unsere Worte."})

      %{organization: organization, owner: owner, post: post}
    end

    test "lives under the organization slug and renders the post", ctx do
      %{organization: organization, post: post, conn: conn} = ctx

      assert Posts.path(post) == "/organizations/#{organization.slug}/posts/#{post.id}"

      html = conn |> get(Posts.path(post)) |> html_response(200)
      assert html =~ "Unsere Worte."
    end

    test "404s for an id that is not this organization's post", ctx do
      %{organization: organization, conn: conn} = ctx
      stranger = insert(:activated_user)
      {:ok, personal} = Posts.create_post(stranger, %{body: "Meins."})

      # A member's post must never render under an organization's name.
      conn
      |> get(~p"/organizations/#{organization.slug}/posts/#{personal.id}")
      |> response(404)

      conn
      |> get(~p"/organizations/#{organization.slug}/posts/not-a-uuid")
      |> response(404)
    end
  end

  describe "the permalink's agent formats" do
    setup do
      owner = insert(:activated_user)
      organization = active_organization_for(owner)
      {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)

      {:ok, post} =
        Posts.create_organization_post(organization, owner, %{body: "Maschinenlesbar."})

      %{organization: organization, owner: owner, post: post}
    end

    test "serves .md/.txt/.json/.xml, signed by the organization", ctx do
      %{post: post, organization: organization, conn: conn} = ctx
      path = Posts.path(post)

      for extension <- ~w(.md .txt .json) do
        body = conn |> get(path <> extension) |> response(200)
        assert body =~ "Maschinenlesbar."
        assert body =~ organization.name
      end

      json = conn |> get(path <> ".json") |> json_response(200)
      assert json["type"] == "organization_post"
      assert json["author"]["slug"] == organization.slug

      # The member who pressed publish is internal and must not leak into a
      # document anybody can fetch — that split is what `acting_user_id` is for.
      refute json |> Jason.encode!() |> String.contains?(ctx.owner.username)
    end

    test "a page with the agent formats switched off 404s them", ctx do
      %{post: post, organization: organization, conn: conn} = ctx
      {:ok, _} = Organizations.update_organization(organization, %{"geo?" => false})

      conn |> get(Posts.path(post) <> ".md") |> response(404)
      # …while the HTML page itself still renders.
      assert conn |> get(Posts.path(post)) |> html_response(200) =~ "Maschinenlesbar."
    end
  end

  describe "discoverability" do
    test "an organization post is in the sitemap, and drops out when the page opts out", ctx do
      %{conn: conn} = ctx
      owner = insert(:activated_user)
      organization = active_organization_for(owner)
      {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
      {:ok, post} = Posts.create_organization_post(organization, owner, %{body: "Findbar."})

      # `post_entries/1` inner-joins users to build the URL, so an organization
      # post is invisible to it — silently. Its own chunk type is what puts it
      # in front of a crawler at all.
      paths = Vutuv.Sitemap.organization_post_entries(1) |> Enum.map(&elem(&1, 0))
      assert Posts.path(post) in paths

      {:ok, _} = Organizations.update_organization(organization, %{"seo?" => false})

      refute Posts.path(post) in (Vutuv.Sitemap.organization_post_entries(1)
                                  |> Enum.map(&elem(&1, 0)))

      # And /llms.txt names the shape so an agent knows the URL exists.
      assert conn |> get(~p"/llms.txt") |> response(200) =~
               "/organizations/<slug>/posts/<id>"
    end
  end

  describe "the RSS feed" do
    test "serves the page's own posts, signed by the page", %{conn: conn} do
      owner = insert(:activated_user)
      organization = active_organization_for(owner)
      {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
      {:ok, _} = Posts.create_organization_post(organization, owner, %{body: "Neuigkeit."})

      path = VutuvWeb.Feeds.organization_feed_path(organization)
      assert path == "/organizations/#{organization.slug}/posts/feed.xml"

      conn = get(conn, path)
      assert response_content_type(conn, :xml) =~ "application/rss+xml"

      body = response(conn, 200)
      assert body =~ "Neuigkeit."
      assert body =~ "<dc:creator>#{organization.name}</dc:creator>"
      # The member who pressed publish never appears in a feed.
      refute body =~ owner.username
    end

    test "a page still in the moderation freezer serves no feed", %{conn: conn} do
      owner = insert(:activated_user)
      organization = active_organization_for(owner)
      {:ok, _} = Organizations.admin_set_frozen(organization, true)

      conn
      |> get(VutuvWeb.Feeds.organization_feed_path(organization))
      |> response(404)
    end
  end

  describe "public search" do
    test "the results page renders an organization row without a member author",
         %{conn: conn} do
      owner = insert(:activated_user)
      organization = active_organization_for(owner)
      {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)

      {:ok, _} =
        Posts.create_organization_post(organization, owner, %{body: "Quantenkompressor."})

      # The query change is only half of it: the last three crashes in this
      # milestone were all a page reading `post.user` on an organization post,
      # so the row has to draw as well as be found.
      {:ok, _view, html} = live(conn, ~p"/search?q=Quantenkompressor")

      assert html =~ organization.name
      assert html =~ "Quantenkompressor"
    end
  end

  describe "the site-wide feed" do
    setup do
      owner = insert(:activated_user)
      organization = active_organization_for(owner)
      {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
      {:ok, post} = Posts.create_organization_post(organization, owner, %{body: "Für alle."})

      %{organization: organization, owner: owner, post: post}
    end

    test "carries a page's post", %{conn: conn, organization: organization} do
      body = conn |> get(~p"/posts/feed.xml") |> response(200)

      assert body =~ "Für alle."
      assert body =~ "<dc:creator>#{organization.name}</dc:creator>"
    end

    test "leaves out a page that opted out of either machine channel", ctx do
      %{conn: conn, organization: organization} = ctx

      # The site feed aggregates only authors who opted out of nothing — for a
      # member that is `noindex?`/`noai?`, for a page `seo?`/`geo?`.
      {:ok, _} = Organizations.update_organization(organization, %{"geo?" => false})
      refute conn |> get(~p"/posts/feed.xml") |> response(200) =~ "Für alle."
    end
  end

  describe "replies" do
    defp page_post(owner, body) do
      organization = active_organization_for(owner)
      {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
      {:ok, post} = Posts.create_organization_post(organization, owner, %{body: body})
      {organization, post}
    end

    defp page_post(body \\ "Hallo."), do: page_post(insert(:activated_user), body)

    test "a member answers a page's post, and the row names the page as the parent author" do
      {organization, post} = page_post()
      reader = insert(:activated_user)

      assert {:ok, reply} = Posts.create_reply(reader, post, %{body: "Antwort"})

      # The page-shaped half of the pair `parent_author_id` is for a member: it
      # is what the page's activity list reads, and what keeps the reply
      # nameable once the page deletes the post it answers.
      assert reply.reply_ref.parent_post_id == post.id
      assert reply.reply_ref.parent_organization_id == organization.id
      assert is_nil(reply.reply_ref.parent_author_id)
    end

    test "the reply page names the page and its composer works", %{conn: conn} do
      # Logging in first: `sent_pin/0` reads the oldest mail in the box, so a
      # page created before it would put its own mail in front of the PIN.
      {conn, reader} = create_and_login_user(conn)
      {organization, post} = page_post("Wir stellen ein.")

      {:ok, live, html} = live(conn, ~p"/posts/#{post.id}/reply")

      # A page has no handle to speak of, so it is named by its name — the
      # heading used to reach for `@parent.user.username`, which a page's post
      # has not got, and the gate above it turned every such visitor away with
      # "page not found".
      assert html =~ organization.name
      assert html =~ "composer-form"

      live
      |> form("#composer-form", %{"post" => %{"body" => "Ich bewerbe mich."}})
      |> render_submit()

      assert_redirect(live, Posts.path(post))
      assert [reply] = Posts.list_replies(post, reader)
      assert reply.body == "Ich bewerbe mich."
    end

    test "the answer shows up under the page's post and names what it answers", %{conn: conn} do
      {organization, post} = page_post()
      reader = insert(:activated_user, first_name: "Rita", last_name: "Leserin")
      {:ok, _reply} = Posts.create_reply(reader, post, %{body: "Meine Antwort"})

      html = conn |> get(Posts.path(post)) |> html_response(200)

      # The permalink hosts the conversation now (`PostLive.Thread`); without it
      # an answer to a page's post would be written into a void.
      assert html =~ "Meine Antwort"
      assert html =~ "Rita Leserin"
      # And the answer's own card says whom it answers, by the page's name.
      assert html =~ organization.name
    end

    test "a post of a page that is not publicly visible stays unanswerable", %{conn: conn} do
      {conn, _reader} = create_and_login_user(conn)
      {organization, post} = page_post()

      {:ok, _} =
        organization |> Ecto.Changeset.change(%{status: "pending"}) |> Vutuv.Repo.update()

      # `visible_to?/2` deliberately does not ask whether the page is visible —
      # that lives in the queries, which is right for every list. The reply page
      # renders the parent card from an id in the URL, so without
      # `answerable?/1` a guessed id would confirm and quote it.
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/posts/#{post.id}/reply")

      assert {:error, :not_visible} =
               Posts.create_reply(insert(:activated_user), post, %{body: "Antwort"})
    end

    test "and it is still there once the socket connects", %{conn: conn} do
      {_organization, post} = page_post()
      reader = insert(:activated_user)
      {:ok, _reply} = Posts.create_reply(reader, post, %{body: "Meine Antwort"})

      # The conversation is a LiveView nested inside this page's LiveView, so
      # its dead render is thrown away and re-mounted on connect: a page that
      # only renders statically would look right in the assertion above and be
      # empty in a browser.
      {:ok, view, _html} = live(conn, Posts.path(post))

      thread =
        Enum.find(live_children(view), &(&1.module == VutuvWeb.PostLive.Thread))

      assert render(thread) =~ "Meine Antwort"
    end

    test "the answer's agent-format siblings name the page they answer", %{conn: conn} do
      {organization, post} = page_post()
      reader = insert(:activated_user)
      {:ok, reply} = Posts.create_reply(reader, post, %{body: "Meine Antwort"})

      # `UserHelpers.full_name/1` has no clause for a page, so the `.md`/`.json`
      # sibling of an answer to one used to be a 500 where the HTML card renders
      # fine — the drift the agent-doc rule exists to catch.
      assert conn |> get(Posts.path(reply) <> ".md") |> response(200) =~ organization.name

      json = conn |> get(Posts.path(reply) <> ".json") |> json_response(200)
      assert json["in_reply_to"]["author"] == organization.name
      assert json["in_reply_to"]["url"] =~ Posts.path(post)
    end

    test "the page's team learns about it on the activity page", %{conn: conn} do
      {conn, owner} = create_and_login_user(conn)
      {organization, post} = page_post(owner, "Hallo.")
      reader = insert(:activated_user, first_name: "Rita", last_name: "Leserin")
      {:ok, reply} = Posts.create_reply(reader, post, %{body: "Meine Antwort"})

      # Derived from the reply row like the page's likes and reposts, so nothing
      # is written twice — and this is the list that receives an answer at all,
      # since there is no member to notify and one row per publisher would
      # contradict the single shared read marker.
      assert organization.id
             |> Organizations.get_organization!()
             |> Organizations.unread_activity_count() == 1

      {:ok, _view, html} = live(conn, ~p"/organizations/#{organization.slug}/activity")

      assert html =~ "Rita Leserin"
      # The entry links to the ANSWER — that is what the team wants to read.
      assert html =~ Posts.path(reply)
    end
  end
end
