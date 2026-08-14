defmodule Vutuv.NodeInfoTest do
  @moduledoc """
  The NodeInfo document (issue #1448): what an installation tells the
  fediverse's directory layer about itself.

  The figures are the interesting part. `usage.users.total` must be the
  **members here** and never the top bar's people total, which adds the remote
  accounts that follow this installation — those live on other servers and
  counting them here would double-count them across the network. The active
  windows must come from the same population as the total, or a directory sees
  more active members than members.
  """

  use Vutuv.DataCase, async: true

  alias Vutuv.Accounts
  alias Vutuv.Fediverse.Follower
  alias Vutuv.Legal
  alias Vutuv.NodeInfo
  alias Vutuv.Posts
  alias Vutuv.Posts.PostDenial
  alias Vutuv.Sessions.UserSession
  alias Vutuv.Token

  describe "links/0" do
    test "advertises 2.1 before 2.0, each with an absolute href" do
      assert [twenty_one, twenty] = NodeInfo.links()

      assert twenty_one["rel"] == "http://nodeinfo.diaspora.software/ns/schema/2.1"
      assert twenty_one["href"] == "http://localhost:4001/system/nodeinfo/2.1"
      assert twenty["rel"] == "http://nodeinfo.diaspora.software/ns/schema/2.0"
      assert twenty["href"] == "http://localhost:4001/system/nodeinfo/2.0"
    end
  end

  describe "document/1" do
    test "2.1 carries the required fields plus the repository pointers" do
      doc = NodeInfo.document("2.1")

      assert doc["version"] == "2.1"
      assert doc["protocols"] == ["activitypub"]
      assert doc["services"] == %{"inbound" => [], "outbound" => []}
      assert doc["openRegistrations"] == true

      assert doc["software"]["name"] == "vutuv"
      assert doc["software"]["version"] == to_string(Application.spec(:vutuv, :vsn))
      assert doc["software"]["repository"] == "https://github.com/wintermeyer/vutuv"
      # The apex, never the `www.` alias, which only 301s here.
      assert doc["software"]["homepage"] == "https://vutuv.de"

      assert doc["metadata"]["nodeName"] == "vutuv"
      assert doc["metadata"]["nodeDescription"] =~ "business network"
    end

    test "2.0 says 2.0 and drops the 2.1-only software fields" do
      doc = NodeInfo.document("2.0")

      assert doc["version"] == "2.0"
      assert doc["software"]["name"] == "vutuv"
      refute Map.has_key?(doc["software"], "repository")
      refute Map.has_key?(doc["software"], "homepage")
    end

    test "the software name matches the schema's ^[a-z0-9-]+$ pattern" do
      assert NodeInfo.document("2.1")["software"]["name"] =~ ~r/\A[a-z0-9-]+\z/
    end

    test "an unknown schema version has no document" do
      assert NodeInfo.document("1.0") == nil
      assert NodeInfo.document("2.2") == nil
    end
  end

  describe "metadata" do
    test "the description states what is true of the software everywhere" do
      description = NodeInfo.document("2.1")["metadata"]["nodeDescription"]

      assert description =~ "open-source"
      assert description =~ "no third-party cookies"
    end

    test "the hosting claim names the operator's own data location" do
      # The one claim in the description that is NOT a property of the
      # software: `data_location` is the operator's own, exactly as on the
      # start page.
      assert NodeInfo.document("2.1")["metadata"]["nodeDescription"] =~
               "on our own hardware in Deutschland"
    end

    test "langs lists the locales this installation serves" do
      assert NodeInfo.document("2.1")["metadata"]["langs"] == ["en", "de"]
    end

    test "maintainer is the operator contact, the one security.txt already names" do
      maintainer = NodeInfo.document("2.1")["metadata"]["maintainer"]

      assert maintainer == %{
               "name" => "Stefan Wintermeyer",
               "email" => "sw@wintermeyer-consulting.de"
             }
    end

    test "an unwritten legal page is not advertised" do
      metadata = NodeInfo.document("2.1")["metadata"]

      refute Map.has_key?(metadata, "tosUrl")
      refute Map.has_key?(metadata, "privacyPolicyUrl")
    end

    test "a written legal page is linked absolutely" do
      {:ok, _} = Legal.upsert_page("nutzungsbedingungen", %{"body" => "# Terms"})
      {:ok, _} = Legal.upsert_page("datenschutzerklaerung", %{"body" => "# Privacy"})

      metadata = NodeInfo.document("2.1")["metadata"]

      assert metadata["tosUrl"] == "http://localhost:4001/nutzungsbedingungen"
      assert metadata["privacyPolicyUrl"] == "http://localhost:4001/datenschutzerklaerung"
    end
  end

  describe "usage/0" do
    test "users.total counts the members here, not the top bar's people total" do
      before = NodeInfo.usage().users.total

      insert(:activated_user)
      followed = insert(:activated_user)
      # A remote account following a member is another server's account: the top
      # bar adds it to the people total, and this figure must not.
      Repo.insert!(%Follower{
        user_id: followed.id,
        actor_uri: "https://remote.example/users/ada",
        inbox_uri: "https://remote.example/users/ada/inbox"
      })

      assert NodeInfo.usage().users.total == before + 2
      assert NodeInfo.usage().users.total == Accounts.count_users()
    end

    test "an unconfirmed sign-up is not a member yet" do
      before = NodeInfo.usage().users.total

      insert(:user, email_confirmed?: false)

      assert NodeInfo.usage().users.total == before
    end

    test "the active windows count members by their most recent session" do
      base = NodeInfo.usage()

      recent = insert(:activated_user)
      older = insert(:activated_user)
      gone = insert(:activated_user)

      # Two devices for one member: the figure counts people, not sessions.
      seen(recent, -1)
      seen(recent, -3)
      seen(older, -90)
      seen(gone, -200)

      usage = NodeInfo.usage()

      assert usage.users.active_month == base.users.active_month + 1
      assert usage.users.active_halfyear == base.users.active_halfyear + 2
    end

    test "a signed-out device still proves the member signed in" do
      base = NodeInfo.usage()

      member = insert(:activated_user)
      member |> seen(-2) |> Ecto.Changeset.change(revoked_at: now()) |> Repo.update!()

      assert NodeInfo.usage().users.active_month == base.users.active_month + 1
    end

    test "an active window never exceeds the member total" do
      member = insert(:activated_user)
      seen(member, 0)

      usage = NodeInfo.usage()

      assert usage.users.active_month <= usage.users.total
      assert usage.users.active_halfyear <= usage.users.total
    end

    test "localPosts counts public posts and localComments their replies" do
      base = NodeInfo.usage()

      author = insert(:activated_user)
      {:ok, post} = Posts.create_post(author, %{"body" => "A post"})
      {:ok, _reply} = Posts.create_reply(author, post, %{"body" => "A reply"})

      usage = NodeInfo.usage()

      assert usage.local_posts == base.local_posts + 1
      assert usage.local_comments == base.local_comments + 1
    end

    test "a post nobody may see is in neither figure" do
      author = insert(:activated_user)
      {:ok, post} = Posts.create_post(author, %{"body" => "Hidden"})
      base = NodeInfo.usage()

      Repo.insert!(%PostDenial{post_id: post.id, wildcard: "everyone"})

      assert NodeInfo.usage().local_posts == base.local_posts - 1
    end
  end

  # One signed-in device for `user`, last seen `days_ago` days ago.
  defp seen(user, days_ago) do
    Repo.insert!(%UserSession{
      user_id: user.id,
      token_hash: Token.random_token(),
      last_seen_at: DateTime.add(now(), days_ago, :day)
    })
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
