defmodule Vutuv.OrganizationRemoteFollowTest do
  @moduledoc """
  A page follows an account on another network (#1336's last open point) — the
  direction that was blocked until #1334 gave a page an actor, because a Follow
  has to be signed by somebody.

  The round trip is the thing: the page asks, the other server answers, and only
  then does that account's material reach the page's feed. A request nobody
  answered must not leak a locked account's posts, which is the one gate this
  shares with the member side.

  `async: false` because the organization helpers flip the global
  `:verify_organization_domains` flag and the remote fetch is stubbed through
  the application env.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.OrganizationsHelpers

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.BlockedInstance
  alias Vutuv.Fediverse.Delivery
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Posts
  alias Vutuv.Repo
  alias VutuvWeb.Fediverse.Docs

  @actor "https://social.example/users/alice"

  setup do
    Application.put_env(:vutuv, :verify_organization_domains, true)

    on_exit(fn ->
      Application.put_env(:vutuv, :verify_organization_domains, false)
      Application.delete_env(:vutuv, :organizations_dns_resolver)
    end)

    :ok
  end

  defp federating_page do
    page =
      active_organization_for(insert(:activated_user))
      |> Ecto.Changeset.change(%{fediverse_followers?: true, username: "acme"})
      |> Repo.update!()

    {:ok, _} = Fediverse.ensure_actor(page)
    page
  end

  defp remote_account do
    Repo.insert!(%RemoteAccount{
      actor_uri: @actor,
      host: "social.example",
      inbox_uri: @actor <> "/inbox",
      handle: "@alice@social.example",
      name: "Alice"
    })
  end

  defp requested_follow(page, account) do
    id = Vutuv.UUIDv7.generate()

    Repo.insert!(%Follow{
      id: id,
      organization_id: page.id,
      remote_account_id: account.id,
      state: "requested",
      follow_activity_id: Docs.follow_activity_id(page, id)
    })
  end

  test "the database refuses a follow naming both followers or neither" do
    page = federating_page()
    account = remote_account()
    member = insert(:activated_user)

    assert_raise Ecto.ConstraintError, ~r/fediverse_follows_exactly_one_follower/, fn ->
      Repo.insert!(%Follow{
        user_id: member.id,
        organization_id: page.id,
        remote_account_id: account.id,
        state: "requested",
        follow_activity_id: "https://example.test/a"
      })
    end

    assert_raise Ecto.ConstraintError, ~r/fediverse_follows_exactly_one_follower/, fn ->
      Repo.insert!(%Follow{
        remote_account_id: account.id,
        state: "requested",
        follow_activity_id: "https://example.test/b"
      })
    end
  end

  test "the same page cannot ask twice" do
    page = federating_page()
    account = remote_account()
    requested_follow(page, account)

    # `[user_id, remote_account_id]` cannot police this: both rows leave
    # user_id NULL, and Postgres treats NULLs as distinct.
    assert_raise Ecto.ConstraintError, fn -> requested_follow(page, account) end
  end

  test "an Accept moves the page's request to accepted" do
    page = federating_page()
    account = remote_account()
    follow = requested_follow(page, account)

    :ok =
      Fediverse.accept_organization_remote_follow(
        page,
        %{"type" => "Accept", "object" => follow.follow_activity_id},
        @actor
      )

    assert Repo.get!(Follow, follow.id).state == "accepted"
  end

  test "an Accept from one server cannot settle another page's request" do
    page = federating_page()

    other =
      active_organization_for(insert(:activated_user), %{
        "name" => "Zweite AG",
        "website_url" => "https://zweite.example"
      })
      |> Ecto.Changeset.change(%{fediverse_followers?: true, username: "zweite"})
      |> Repo.update!()

    account = remote_account()
    follow = requested_follow(page, account)

    # Addressed with the *other* page: the row belongs to neither that page nor
    # anybody it may answer for, so it must stay untouched.
    :ok =
      Fediverse.accept_organization_remote_follow(
        other,
        %{"type" => "Accept", "object" => follow.follow_activity_id},
        @actor
      )

    assert Repo.get!(Follow, follow.id).state == "requested"
  end

  test "a Reject removes the row" do
    page = federating_page()
    account = remote_account()
    follow = requested_follow(page, account)

    :ok =
      Fediverse.reject_organization_remote_follow(
        page,
        %{"type" => "Reject", "object" => follow.follow_activity_id},
        @actor
      )

    refute Repo.get(Follow, follow.id)
  end

  describe "the page's feed" do
    defp remote_post(account, audience) do
      Repo.insert!(%RemotePost{
        remote_account_id: account.id,
        object_uri: "https://social.example/notes/#{System.unique_integer([:positive])}",
        content_text: "Von drüben.",
        audience: audience,
        published_at: DateTime.utc_now(:second),
        received_at: DateTime.utc_now(:second),
        expires_at: DateTime.add(DateTime.utc_now(:second), 30, :day)
      })
    end

    defp feed_ids(page) do
      page
      |> Posts.organization_feed_page()
      |> Map.fetch!(:entries)
      |> Enum.map(& &1[:remote_post])
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.id)
    end

    test "carries a public post from an account it merely asked to follow" do
      page = federating_page()
      account = remote_account()
      requested_follow(page, account)

      post = remote_post(account, "public")

      assert post.id in feed_ids(page)
    end

    test "withholds a locked account's post until the follow was accepted" do
      page = federating_page()
      account = remote_account()
      follow = requested_follow(page, account)

      post = remote_post(account, "followers")

      # An unanswered request must not leak what a locked account posts — the
      # one gate this shares with the member feed.
      refute post.id in feed_ids(page)

      follow |> Follow.accept() |> Repo.update!()
      assert post.id in feed_ids(page)
    end

    test "the account timeline uses the page's own accepted follow" do
      page = federating_page()
      account = remote_account()
      follow = requested_follow(page, account)
      post = remote_post(account, "followers")

      {before_accept, _more?} = Fediverse.account_posts(account, page)
      refute Enum.any?(before_accept, &(&1.id == post.id))

      follow |> Follow.accept() |> Repo.update!()

      {after_accept, _more?} = Fediverse.account_posts(account, page)
      assert Enum.any?(after_accept, &(&1.id == post.id))
    end
  end

  test "a page that does not federate cannot ask at all" do
    page =
      active_organization_for(insert(:activated_user))
      |> Ecto.Changeset.change(%{username: "acme"})
      |> Repo.update!()

    assert {:error, :not_federated} =
             Fediverse.follow_remote_as_organization(page, "@alice@social.example")

    assert Repo.aggregate(Delivery, :count) == 0
  end

  test "the total ceiling refuses one more follow (issue #1601)" do
    Application.put_env(:vutuv, :fediverse_max_remote_follows, 1)
    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_max_remote_follows) end)

    page = federating_page()
    account = remote_account()
    requested_follow(page, account)

    assert {:error, :follow_limit} =
             Fediverse.follow_remote_as_organization(page, "@other@social.example")
  end

  # Pinned by name because `gettext.extract --merge` fuzzy-filled exactly this
  # msgid with the member wording ("Sie folgen bereits …") — the wrong voice:
  # the reader acts for the page, they are not the follower.
  test "the German ceiling refusal speaks for the page, not the member" do
    # No restore needed: the locale lives in this test process's dictionary
    # and dies with it.
    Gettext.put_locale(VutuvWeb.Gettext, "de")

    text =
      Gettext.gettext(
        VutuvWeb.Gettext,
        "This page is following the most accounts we allow (%{max}).",
        max: "1.000"
      )

    assert text == "Diese Seite folgt bereits so vielen Konten, wie hier erlaubt sind (1.000)."
  end

  describe "unfollow_remote/2 for a page" do
    test "queues no Undo for a blocklisted instance but still deletes the row (issue #1600)" do
      page = federating_page()
      account = remote_account()
      follow = requested_follow(page, account)

      # The bare row rather than `block_instance/2`: the admin flow purges every
      # follow of the host in the same act, so the state this filter guards is
      # the race window where the block lands while a follow still exists —
      # exactly what the member path's `deliverable_undo?/2` exists for.
      Repo.insert!(%BlockedInstance{host: "social.example"})

      :ok = Fediverse.unfollow_remote(page, follow.id)

      refute Repo.get(Follow, follow.id)
      assert Repo.aggregate(Delivery, :count) == 0
    end

    test "answers not_found for a malformed follow id (issue #1600)" do
      page = federating_page()

      assert {:error, :not_found} =
               Fediverse.unfollow_remote(page, "not-a-uuid")
    end
  end
end
