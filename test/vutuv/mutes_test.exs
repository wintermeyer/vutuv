defmodule Vutuv.MutesTest do
  @moduledoc """
  Silencing an account the reader does not follow.

  The case that made this necessary: a member follows Doris, Doris boosts the
  same account every day, and that account is one nobody here follows — so
  there is no follow edge to carry `muted`, and the only ways out were
  reporting the post (which deletes our copy for everybody) or unfollowing
  Doris.

  The second scope is the other half of the same complaint: keep the account,
  drop what it passes on.
  """
  use Vutuv.DataCase, async: true

  import Vutuv.MastodonHelpers, only: [remote_account: 1, cached_post: 2]

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.PostBoost
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Mutes
  alias Vutuv.Posts
  alias Vutuv.Social

  defp member, do: insert(:activated_user, fediverse_followers?: true)

  # Through the shared helper, which mints a unique `actor_uri` per call: a
  # literal one in an `async: true` file convoys on its unique index with every
  # other file that spells the same address.
  defp account(handle), do: remote_account(handle: handle, name: String.capitalize(handle))

  defp follow(user, %RemoteAccount{} = acc) do
    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: acc.id,
      state: "accepted",
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#f/#{acc.id}"
    })
  end

  # The shared helper again, with the age this test needs: two rows minted in
  # the same second would leave the feed's order to the id tiebreaker.
  defp cached(%RemoteAccount{} = acc, text, minutes_ago \\ 5) do
    at = DateTime.add(DateTime.utc_now(:second), -minutes_ago * 60, :second)
    cached_post(acc, content_text: text, published_at: at)
  end

  defp boost(%RemoteAccount{} = booster, %RemotePost{} = post, minutes_ago \\ 3) do
    Repo.insert!(%PostBoost{
      remote_account_id: booster.id,
      remote_post_id: post.id,
      activity_id: "https://friendica.example/act/#{System.unique_integer([:positive])}",
      announced_at: DateTime.add(DateTime.utc_now(:second), -minutes_ago * 60, :second)
    })
  end

  # The other half of the same table: an account out there passing on a post
  # written **here**, which is how a member gets read on another network.
  defp boost_local(%RemoteAccount{} = booster, post, minutes_ago \\ 3) do
    Repo.insert!(%PostBoost{
      remote_account_id: booster.id,
      post_id: post.id,
      activity_id: "https://friendica.example/act/#{System.unique_integer([:positive])}",
      announced_at: DateTime.add(DateTime.utc_now(:second), -minutes_ago * 60, :second)
    })
  end

  defp local_post(author, body) do
    Vutuv.PostsHelpers.create_post!(Repo.reload!(author), %{body: body})
  end

  defp feed_texts(user) do
    user
    |> Posts.feed_page(limit: 20)
    |> Map.fetch!(:entries)
    |> Enum.map(fn entry ->
      cond do
        entry[:remote_post] -> entry.remote_post.content_text
        entry[:post] -> entry.post.body
        true -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  describe "muting an account nobody here follows" do
    test "a boosted account's posts leave the feed, and the booster's own stay" do
      reader = member()
      doris = account("doris")
      lilly = account("lilly")
      follow(reader, doris)

      boost(doris, cached(lilly, "Lillys Tagebuch"))
      cached(doris, "Doris schreibt selbst")

      assert "Lillys Tagebuch" in feed_texts(reader)

      {:ok, _} = Mutes.mute(reader, lilly, :all)

      refute "Lillys Tagebuch" in feed_texts(reader)
      assert "Doris schreibt selbst" in feed_texts(reader)
    end

    test "muting the booster's reposts keeps the booster's own posts" do
      reader = member()
      doris = account("doris")
      lilly = account("lilly")
      follow(reader, doris)

      boost(doris, cached(lilly, "Lillys Tagebuch"))
      cached(doris, "Doris schreibt selbst")

      {:ok, _} = Mutes.mute(reader, doris, :reposts)

      texts = feed_texts(reader)
      refute "Lillys Tagebuch" in texts
      assert "Doris schreibt selbst" in texts
    end

    test "a mute of the author survives a second account passing them on" do
      reader = member()
      doris = account("doris")
      erna = account("erna")
      lilly = account("lilly")
      follow(reader, doris)
      follow(reader, erna)

      post = cached(lilly, "Lillys Tagebuch")
      boost(doris, post, 4)
      {:ok, _} = Mutes.mute(reader, lilly, :all)

      boost(erna, post, 2)

      refute "Lillys Tagebuch" in feed_texts(reader)
    end
  end

  describe "members and pages here" do
    test "a muted member's post does not arrive through somebody else's repost" do
      reader = member()
      resharer = member()
      stranger = member()
      {:ok, _} = Social.follow(reader, resharer.id)

      post = local_post(stranger, "Vom Fremden")
      :ok = Posts.repost_post(Repo.reload!(resharer), post)

      assert "Vom Fremden" in feed_texts(reader)

      {:ok, _} = Mutes.mute(reader, stranger, :all)

      refute "Vom Fremden" in feed_texts(reader)
    end

    test "muting a followed member's reposts keeps their own posts" do
      reader = member()
      resharer = member()
      stranger = member()
      {:ok, _} = Social.follow(reader, resharer.id)

      :ok = Posts.repost_post(Repo.reload!(resharer), local_post(stranger, "Vom Fremden"))
      local_post(resharer, "Eigener Beitrag")

      {:ok, _} = Mutes.mute(reader, resharer, :reposts)

      texts = feed_texts(reader)
      refute "Vom Fremden" in texts
      assert "Eigener Beitrag" in texts
    end

    test "a muted member's answer under the reader's own post stays out of the feed" do
      reader = member()
      stranger = member()

      mine = local_post(reader, "Meine Frage")

      {:ok, reply} =
        Posts.create_reply(Repo.reload!(stranger), mine, %{body: "Antwort vom Fremden"})

      assert reply.body == "Antwort vom Fremden"
      assert "Antwort vom Fremden" in feed_texts(reader)

      {:ok, _} = Mutes.mute(reader, stranger, :all)

      refute "Antwort vom Fremden" in feed_texts(reader)
    end
  end

  describe "reposts of an account, whoever passes them on" do
    test "what a followed account boosts of a silenced author stays out" do
      reader = member()
      doris = account("doris")
      lilly = account("lilly")
      follow(reader, doris)

      boost(doris, cached(lilly, "Lillys Tagebuch"))
      cached(doris, "Doris schreibt selbst")

      assert "Lillys Tagebuch" in feed_texts(reader)

      {:ok, _} = Mutes.mute(reader, lilly, :reposts_of)

      texts = feed_texts(reader)
      refute "Lillys Tagebuch" in texts
      assert "Doris schreibt selbst" in texts
    end

    test "and the silenced author keeps speaking to whoever follows them" do
      reader = member()
      lilly = account("lilly")
      follow(reader, lilly)

      cached(lilly, "Lilly schreibt selbst")

      {:ok, _} = Mutes.mute(reader, lilly, :reposts_of)

      # The whole difference to `:all`: the account is still heard, only what
      # other people pass on of it is not — so the follow's flag stays down.
      assert "Lilly schreibt selbst" in feed_texts(reader)
      assert Mutes.scope_for(reader, lilly) == :reposts_of
      refute Repo.get_by!(Follow, user_id: reader.id, remote_account_id: lilly.id).muted
    end

    test "a second account passing the same author on is silenced too" do
      reader = member()
      doris = account("doris")
      erna = account("erna")
      lilly = account("lilly")
      follow(reader, doris)
      follow(reader, erna)

      post = cached(lilly, "Lillys Tagebuch")
      boost(doris, post, 4)
      {:ok, _} = Mutes.mute(reader, lilly, :reposts_of)
      boost(erna, post, 2)

      refute "Lillys Tagebuch" in feed_texts(reader)
    end

    test "a member here is silenced the same way" do
      reader = member()
      resharer = member()
      stranger = member()
      {:ok, _} = Social.follow(reader, resharer.id)

      :ok = Posts.repost_post(Repo.reload!(resharer), local_post(stranger, "Vom Fremden"))
      local_post(resharer, "Eigener Beitrag")

      assert "Vom Fremden" in feed_texts(reader)

      {:ok, _} = Mutes.mute(reader, stranger, :reposts_of)

      texts = feed_texts(reader)
      refute "Vom Fremden" in texts
      assert "Eigener Beitrag" in texts
    end

    test "and a member the reader follows keeps arriving with their own posts" do
      reader = member()
      author = member()
      {:ok, _} = Social.follow(reader, author.id)

      local_post(author, "Eigener Beitrag")

      {:ok, _} = Mutes.mute(reader, author, :reposts_of)

      assert "Eigener Beitrag" in feed_texts(reader)

      refute Repo.get_by!(Vutuv.Social.Follow, follower_id: reader.id, followee_id: author.id).muted
    end

    test "a boost carrying a vutuv post reads the same rule" do
      reader = member()
      doris = account("doris")
      author = member()
      follow(reader, doris)

      boost_local(doris, local_post(author, "Hier geschrieben"))

      assert "Hier geschrieben" in feed_texts(reader)

      {:ok, _} = Mutes.mute(reader, author, :reposts_of)

      refute "Hier geschrieben" in feed_texts(reader)
    end

    test "a boost of a page's post reads it too" do
      reader = member()
      doris = account("doris")
      follow(reader, doris)

      # The page is built from the factory rather than through the domain
      # check: that one flips a global config key, which would cost this whole
      # file its `async: true`.
      owner = insert(:activated_user)
      page = insert(:organization)
      {:ok, _} = Vutuv.Organizations.add_role(page, owner, "publisher", owner)
      {:ok, post} = Posts.create_organization_post(page, owner, %{body: "Von der Seite"})

      boost_local(doris, post)

      assert "Von der Seite" in feed_texts(reader)

      {:ok, _} = Mutes.mute(reader, page, :reposts_of)

      refute "Von der Seite" in feed_texts(reader)
    end

    test "and a mute placed on the follow's own switch survives a boost" do
      reader = member()
      doris = account("doris")
      followee = member()
      follow(reader, doris)
      {:ok, _} = Social.follow(reader, followee.id)
      {:ok, _} = Social.set_follow_mute(reader, followee, true)

      boost_local(doris, local_post(followee, "Vom Stummgeschalteten"))

      # The follow's flag is the older of the two stores, and the boost source
      # read only the newer one until 2026-09-06 — a mute the member had placed
      # and could see, with the posts arriving anyway.
      refute "Vom Stummgeschalteten" in feed_texts(reader)
    end

    test "a repost arriving live is not counted behind the pill either" do
      reader = member()
      stranger = member()
      post = local_post(stranger, "Vom Fremden")

      {:ok, _} = Mutes.mute(reader, stranger, :reposts_of)

      # The in-memory twin of the queries above. Asked about the post on its
      # own the answer is yes — this mute is about the carrying, not the author.
      assert Posts.reaches_feed?(post, reader)
      refute Posts.reaches_feed?(post, reader, :repost)
    end
  end

  describe "the two stores answer as one" do
    test "a mute of a followed account sets the follow's own flag too" do
      reader = member()
      doris = account("doris")
      follow(reader, doris)

      {:ok, _} = Mutes.mute(reader, doris, :all)

      assert Mutes.scope_for(reader, doris) == :all
      assert Repo.get_by!(Follow, user_id: reader.id, remote_account_id: doris.id).muted
    end

    test "unmute lifts a mute placed through the follow's own switch" do
      reader = member()
      doris = account("doris")
      follow(reader, doris)
      :ok = Fediverse.set_remote_follow_mute(reader, doris.id, true)

      assert Mutes.scope_for(reader, doris) == :all

      :ok = Mutes.unmute(reader, doris)

      assert Mutes.scope_for(reader, doris) == nil
      refute Repo.get_by!(Follow, user_id: reader.id, remote_account_id: doris.id).muted
    end

    test "narrowing to reposts takes the follow's own flag back down" do
      reader = member()
      doris = account("doris")
      follow(reader, doris)

      {:ok, _} = Mutes.mute(reader, doris, :all)
      assert Repo.get_by!(Follow, user_id: reader.id, remote_account_id: doris.id).muted

      {:ok, _} = Mutes.mute(reader, doris, :reposts)

      # Without this the older store still says "everything", the page says
      # "reposts only", and the reader has a silence they cannot see or lift.
      refute Repo.get_by!(Follow, user_id: reader.id, remote_account_id: doris.id).muted
      assert Mutes.scope_for(reader, doris) == :reposts
    end

    test "an unmute on the follow's own switch lifts the row as well" do
      reader = member()
      doris = account("doris")
      follow(reader, doris)
      {:ok, _} = Mutes.mute(reader, doris, :all)

      # What the account page, the following list and the feed band still call.
      :ok = Fediverse.set_remote_follow_mute(reader, doris.id, false)

      assert Mutes.scope_for(reader, doris) == nil
    end

    test "the same for a member, through the local switch" do
      reader = member()
      followee = insert(:activated_user)
      {:ok, _} = Social.follow(reader, followee.id)
      {:ok, _} = Mutes.mute(reader, followee, :all)

      {:ok, _} = Social.set_follow_mute(reader, followee, false)

      assert Mutes.scope_for(reader, followee) == nil
    end

    test "widening a repost mute to the whole account updates the one row" do
      reader = member()
      doris = account("doris")

      {:ok, _} = Mutes.mute(reader, doris, :reposts)
      {:ok, _} = Mutes.mute(reader, doris, :all)

      assert Mutes.scope_for(reader, doris) == :all
      assert Repo.aggregate(Vutuv.Mutes.AccountMute, :count) == 1
    end

    test "the list names both stores once each" do
      reader = member()
      doris = account("doris")
      lilly = account("lilly")
      follow(reader, doris)
      :ok = Fediverse.set_remote_follow_mute(reader, doris.id, true)
      {:ok, _} = Mutes.mute(reader, lilly, :reposts)

      entries = Mutes.list_for_user(reader)

      assert length(entries) == 2

      assert %{target: %RemoteAccount{handle: "lilly"}, scope: :reposts} =
               Enum.find(entries, &(&1.target.id == lilly.id))

      assert %{scope: :all, source: :follow} = Enum.find(entries, &(&1.target.id == doris.id))
    end
  end
end
