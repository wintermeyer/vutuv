defmodule Vutuv.Tags.ExternalFeedSourceTest do
  @moduledoc """
  What the servers a followed tag names put in a member's feed (issue #2127).

  The rows are cached by #2126 for the whole installation, so the question this
  answers is a per-reader one: **whose** feed does one of them reach, and what
  keeps it out. Everything that governs an ordinary card governs these — the
  reader's hidden words and muted tags, their muted servers, the operator's
  instance blocklist — and none of that is asked of the fetcher, which stores
  one row for everybody.

  `async: false` because the flag `:fetch_external_tag_posts` is global.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.ExternalTagHelpers

  alias Vutuv.Accounts.User
  alias Vutuv.ContentFilters
  alias Vutuv.Fediverse
  alias Vutuv.Posts
  alias Vutuv.Tags
  alias Vutuv.Tags.ExternalPost
  alias Vutuv.Tags.ExternalPosts

  @source Vutuv.ExternalTagHelpers.tag_source()
  @author_host Vutuv.ExternalTagHelpers.author_host()

  setup do
    put_config(:fetch_external_tag_posts, true)
    :ok
  end

  defp feed_ids(user) do
    user
    |> Posts.feed_page(limit: 20)
    |> Map.fetch!(:entries)
    |> Enum.map(& &1.id)
  end

  describe "the feed source" do
    setup do
      user = insert(:activated_user)
      tag = insert(:tag)
      follow_tag_through(user, tag)

      {:ok, user: user, tag: tag}
    end

    test "an external post reaches somebody who follows that tag through that server",
         %{user: user, tag: tag} do
      post = external_post(tag, source: @source, text: "EIN FUND VON DRUEBEN")

      assert "external-#{post.id}" in feed_ids(user)
    end

    test "it does not reach a member who follows the tag without that server", %{tag: tag} do
      # Their own follow, and vutuv is the only source it names.
      other = insert(:activated_user)
      {:ok, _follow} = Tags.follow_tag(other, tag)
      post = external_post(tag, source: @source)

      refute "external-#{post.id}" in feed_ids(other)
    end

    test "it does not reach a member who follows nothing", %{tag: tag} do
      stranger = insert(:activated_user)
      post = external_post(tag, source: @source)

      refute "external-#{post.id}" in feed_ids(stranger)
    end

    # What enforces this is `Vutuv.Fediverse.purge_instance/1`, which a block
    # runs: the rows go rather than being filtered out on the way to a reader.
    # `Vutuv.Tags.ExternalPosts.showable_query/0` says why there is deliberately
    # no read-path clause beside it.
    test "a post from a server the operator blocked never appears", %{user: user, tag: tag} do
      post = external_post(tag, source: @source, author_host: @author_host)

      {:ok, {_blocked, _purged}} =
        Fediverse.block_instance(%{"host" => @author_host}, insert(:activated_user))

      refute "external-#{post.id}" in feed_ids(user)
    end

    test "a row the previous release wrote, with no author host, is not drawn",
         %{user: user, tag: tag} do
      post = external_post(tag, source: @source)

      # What the blue/green window leaves behind: this release cannot say whose
      # server such a post is on, and a card would have to claim it is ours.
      Repo.update_all(from(p in ExternalPost, where: p.id == ^post.id), set: [author_host: nil])

      refute "external-#{post.id}" in feed_ids(user)
    end

    test "a server the reader muted in the band never appears", %{user: user, tag: tag} do
      post = external_post(tag, source: @source, author_host: @author_host)

      {:ok, _hosts} = Fediverse.set_host_mute(user, @author_host, true)

      # Re-read: the mute is written to the member's row, and the source reads
      # the list off the struct the caller hands it.
      refute "external-#{post.id}" in feed_ids(Repo.get!(User, user.id))
    end

    test "a report takes it out of the feed and the next pull cannot bring it back",
         %{user: user, tag: tag} do
      post = external_post(tag, source: @source, text: "WAS WEG MUSS")

      assert :ok = ExternalPosts.report(post.id, user)
      refute "external-#{post.id}" in feed_ids(user)

      # The row survives as a tombstone, without its words: the pull's
      # `on_conflict: :nothing` needs the key to be there to do nothing about.
      row = Repo.get!(ExternalPost, post.id)
      assert row.reported_at
      assert row.text == ""
      assert row.author_acct == nil
    end
  end

  # Read through `ContentFilters` rather than through the feed: a rule is
  # matched against the record, and the feed is a longer way to ask the same
  # question of the same struct.
  describe "the reader's own filters" do
    test "a hidden word matches its text" do
      post = external_post(insert(:tag), text: "Ein Beitrag ueber Krypto und mehr")
      user = insert(:activated_user)

      {:ok, _filter} =
        ContentFilters.create_filter(user, %{"kind" => "keyword", "pattern" => "Krypto"})

      assert ContentFilters.filtered(post, ContentFilters.compile_for(user)) == "Krypto"
    end

    test "a muted tag matches it too — the rule is read over the text" do
      post = external_post(insert(:tag), text: "Schoenes Wetter in #Koblenz heute")
      user = insert(:activated_user)

      {:ok, _filter} =
        ContentFilters.create_filter(user, %{"kind" => "tag", "pattern" => "Koblenz"})

      assert ContentFilters.filtered(post, ContentFilters.compile_for(user)) == "Koblenz"
    end
  end

  describe "the record's own facts" do
    test "the author's host is what the card names, not the server we asked" do
      post = external_post(insert(:tag), source: @source, author_host: @author_host)

      assert post.author_host == @author_host
      assert ExternalPost.address(post) == "@ada@#{@author_host}"
      assert ExternalPost.author_username(post) == "ada"
      assert post.source == @source
    end

    test "an author local to the queried server is named on that server" do
      post = external_post(insert(:tag), source: @source, author_host: @source)

      assert ExternalPost.address(post) == "@ada@#{@source}"
    end

    test "the post family answers for it" do
      post = external_post(insert(:tag), text: "WAS DA STEHT", author_name: "Ada Lovelace")

      assert Posts.text(post) == "WAS DA STEHT"
      assert Posts.written_at(post) == post.published_at
      assert "Ada Lovelace" in Posts.account_names(post)
    end
  end
end
