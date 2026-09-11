defmodule VutuvWeb.SettingsPostsMachinesTest do
  @moduledoc """
  The one decision a member takes about machines and their posts (issue #2107):
  on `/settings/privacy`, once, and **stamped onto each post as it is
  published** rather than read back when an old post is rendered.

  That stamping is the whole design. A live read would mean flipping the switch
  silently rewrote six years of posts — including withdrawing copies other
  servers already hold, which nothing can do — so the column on the row is what
  answers, and the setting is only ever its default for the next post.

  The setting is a `Vutuv.Prefs` key rather than a plain `users` column, so a
  member who was never asked (`nil`) inherits the installation default and an
  operator can move it for everybody. Its two neighbours on that page,
  `noindex?` and `noai?`, are the opposite shape — opt-**out** columns with hard
  defaults — and this file asserts they stay independent of it.
  """
  use VutuvWeb.ConnCase, async: false

  alias Vutuv.Organizations
  alias Vutuv.OrganizationsHelpers
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Prefs
  alias Vutuv.Repo

  describe "the setting itself" do
    test "ships allowing machines, so nothing changes for a member who never looked" do
      assert Prefs.default(:posts_machines_allowed?) == true
      assert Prefs.get(insert(:activated_user), :posts_machines_allowed?) == true
    end

    test "is on the Visibility page, and saving no is remembered", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      html = conn |> get(~p"/settings/privacy") |> html_response(200)
      assert html =~ "Search engines and AI may read my posts"
      assert html =~ "posts-machines-form"

      conn =
        conn
        |> recycle()
        |> put(~p"/settings/privacy", %{"user" => %{"posts_machines_allowed?" => "false"}})

      assert redirected_to(conn) == ~p"/settings/privacy"
      assert Repo.reload!(user).posts_machines_allowed? == false
    end

    test "says on that page what only it can say: the post never reaches other networks", %{
      conn: conn
    } do
      {conn, _user} = create_and_login_user(conn)

      html = conn |> get(~p"/settings/privacy") |> html_response(200)

      # The composer used to carry this warning in a panel before publishing.
      # The decision is made here now, so the sentence has to be here — it is
      # the one consequence a member cannot discover by trying it, because a
      # copy on somebody else's server cannot be called back.
      assert html =~ "stay out of other networks completely"
      assert html =~ "keeps its copy for good"
      assert html =~ "keep the answer they went out with"
    end

    test "is findable by searching the settings hub for a word it does not print", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      html = conn |> get(~p"/settings") |> html_response(200)

      # `:terms` is never rendered as text; it rides `data-search`, which the
      # filter box matches. Without it the new setting is on a page nobody can
      # find by typing what they are looking for.
      assert html =~ "beiträge"
      assert html =~ "fediverse"
    end
  end

  describe "the answer is stamped onto the post" do
    test "a member who allows machines publishes posts that allow them" do
      user = insert(:activated_user)

      {:ok, post} = Posts.create_post(user, %{body: "Ganz normal"})

      assert %Post{noindex_noai?: false} = post
      assert Posts.machines_allowed?(post)
    end

    test "a member who said no publishes posts that say no" do
      user = say_no(insert(:activated_user))

      {:ok, post} = Posts.create_post(user, %{body: "Nur für Menschen"})

      assert %Post{noindex_noai?: true} = post
      refute Posts.machines_allowed?(post)
    end

    test "a reply carries the answer too — it is a post like any other" do
      author = insert(:activated_user)
      replier = say_no(insert(:activated_user))

      {:ok, parent} = Posts.create_post(author, %{body: "Frage"})
      {:ok, reply} = Posts.create_reply(replier, parent, %{body: "Antwort"})

      assert %Post{noindex_noai?: true} = reply
    end

    test "changing the setting afterwards leaves the older post exactly as it was" do
      user = insert(:activated_user)
      {:ok, old} = Posts.create_post(user, %{body: "Vorher"})

      user = say_no(user)
      {:ok, new} = Posts.create_post(user, %{body: "Nachher"})

      # This is the promise the whole design exists for: the old post answers
      # from its own column, which nothing re-reads.
      assert Repo.reload!(old).noindex_noai? == false
      assert new.noindex_noai? == true
    end

    test "and editing an old post does not re-ask the setting" do
      user = insert(:activated_user)
      {:ok, post} = Posts.create_post(user, %{body: "Vorher"})

      _user = say_no(user)
      {:ok, edited} = Posts.update_post(post, %{body: "Vorher, korrigiert"})

      assert edited.noindex_noai? == false
    end

    test "an explicit answer in the attrs still wins, which is what the API sends" do
      user = insert(:activated_user)

      {:ok, post} = Posts.create_post(user, %{body: "Ausnahme", noindex_noai: "true"})

      assert post.noindex_noai? == true
    end

    test "a post published in an organization's name does not take the member's answer" do
      # A page has its own `seo?`/`geo?`, and one publisher's private posture
      # must not silently mute the brand they publish for.
      Application.put_env(:vutuv, :verify_organization_domains, true)

      on_exit(fn ->
        Application.put_env(:vutuv, :verify_organization_domains, false)
        Application.delete_env(:vutuv, :organizations_dns_resolver)
      end)

      owner = say_no(insert(:activated_user))
      page = OrganizationsHelpers.active_organization_for(owner)
      {:ok, _} = Organizations.add_role(page, owner, "publisher", owner)

      {:ok, post} = Posts.create_organization_post(page, owner, %{body: "Von uns."})

      assert post.noindex_noai? == false
    end

    test "the two profile opt-outs beside it decide nothing about posts" do
      # `noai?`'s column default is `true` for every member who was never asked,
      # so deriving a post's answer from that pair would have defaulted almost
      # every post out of the Fediverse. They are a separate question about the
      # profile and stay one.
      user = insert(:activated_user, noindex?: true, noai?: true)

      {:ok, post} = Posts.create_post(user, %{body: "Profil zu, Beitrag offen"})

      assert post.noindex_noai? == false
    end
  end

  describe "in German" do
    test "the setting reads as German on the Visibility page", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      html =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/settings/privacy")
        |> html_response(200)

      assert html =~ "Suchmaschinen und KI dürfen meine Beiträge lesen"
      assert html =~ "Ihre Beiträge"
      assert html =~ "gar nicht mehr in andere Netzwerke"
    end
  end

  defp say_no(user) do
    user
    |> Ecto.Changeset.change(posts_machines_allowed?: false)
    |> Repo.update!()
  end
end
