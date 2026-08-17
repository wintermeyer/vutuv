defmodule VutuvWeb.MastodonApi.DeepPaginationTest do
  @moduledoc """
  Walking a list all the way to its end, not just as far as the first read
  happened to reach.

  Every list here used to be answered by fetching the newest `limit + 20` rows
  and then filtering the window out of them in memory. That works for the first
  two pages and then stops dead: once `max_id` is older than the last row
  fetched, the filter has nothing left to keep and the endpoint answers `[]` —
  with a 200, no error and no log line, so a 200-post profile simply looks like
  a 40-post one. `Vutuv.Keyset` puts the boundary in the query instead.

  **Calibrated against the un-fixed code.** These walk with `limit: 1` over
  #{25} rows, so the walk runs past the old 21-row read (`limit + 20`) rather
  than stopping just inside it. Revert `Keyset.scope/3` back to an in-memory
  window and every test here goes red at row 22; a test using a shorter list
  would pass either way and be worth nothing.

  `async: false` because it walks the same endpoints the rate limiter counts.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.MastodonHelpers
  import Vutuv.OrganizationsHelpers

  alias Vutuv.Organizations
  alias Vutuv.Posts
  alias Vutuv.Social

  @rows 25

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  # One request per row plus one, so the walk has to survive going past the end
  # as well as getting there. Stops early if the endpoint repeats itself, which
  # would otherwise spin.
  defp walk(token, path) do
    Enum.reduce_while(1..(@rows + 1), {[], nil}, fn _step, {seen, cursor} ->
      separator = if String.contains?(path, "?"), do: "&", else: "?"
      query = separator <> "limit=1" <> if(cursor, do: "&max_id=#{cursor}", else: "")

      case build_conn() |> mastodon_conn(token) |> get(path <> query) |> json_response(200) do
        [] -> {:halt, {seen, cursor}}
        [%{"id" => id}] -> {:cont, {seen ++ [id], id}}
      end
    end)
    |> elem(0)
  end

  defp assert_walks_everything(token, path) do
    ids = walk(token, path)

    assert length(ids) == @rows,
           "#{path} stopped after #{length(ids)} of #{@rows} rows"

    assert length(Enum.uniq(ids)) == @rows, "#{path} served the same row twice"
    ids
  end

  defp posts_by(author) do
    Enum.map(1..@rows, fn n ->
      {:ok, post} = Posts.create_post(author, %{body: "Beitrag #{n}"})
      post
    end)
  end

  describe "status lists" do
    setup do
      author = insert(:activated_user)
      reader = insert(:activated_user)
      {:ok, author: author, reader: reader, posts: posts_by(author)}
    end

    test "the public timeline walks past the first read", %{reader: reader} do
      assert_walks_everything(mastodon_token(reader, ["read"]), "/api/v1/timelines/public")
    end

    test "an account's own statuses walk past the first read", %{
      author: author,
      reader: reader
    } do
      assert_walks_everything(
        mastodon_token(reader, ["read"]),
        "/api/v1/accounts/#{author.id}/statuses"
      )
    end

    test "bookmarks walk past the first read", %{reader: reader, posts: posts} do
      Enum.each(posts, &Posts.bookmark_post(reader, &1))

      assert_walks_everything(mastodon_token(reader, ["read"]), "/api/v1/bookmarks")
    end

    test "favourites walk past the first read", %{reader: reader, posts: posts} do
      Enum.each(posts, &Posts.like_post(reader, &1))

      assert_walks_everything(mastodon_token(reader, ["read"]), "/api/v1/favourites")
    end

    # A one-word tag name so the hashtag in the body parses; safe as a literal
    # because this module is `async: false`.
    test "a hashtag timeline walks past the first read", %{author: author, reader: reader} do
      tag = insert(:tag, name: "keysetwalk", slug: "keysetwalk")

      Enum.each(1..@rows, fn n ->
        {:ok, _} = Posts.create_post(author, %{body: "Thema #{n} ##{tag.name}"})
      end)

      # Only the tagged posts are on this timeline, so the walk length is the
      # same @rows the shared setup made — the untagged ones are not here.
      assert_walks_everything(
        mastodon_token(reader, ["read"]),
        "/api/v1/timelines/tag/#{tag.slug}"
      )
    end
  end

  describe "account lists" do
    setup do
      subject = insert(:activated_user)
      others = Enum.map(1..@rows, fn _n -> insert(:activated_user) end)
      {:ok, subject: subject, others: others}
    end

    test "followers walk past the first read", %{subject: subject, others: others} do
      Enum.each(others, &Social.follow(&1, subject.id))

      assert_walks_everything(
        mastodon_token(subject, ["read"]),
        "/api/v1/accounts/#{subject.id}/followers"
      )
    end

    test "following walks past the first read", %{subject: subject, others: others} do
      Enum.each(others, &Social.follow(subject, &1.id))

      assert_walks_everything(
        mastodon_token(subject, ["read"]),
        "/api/v1/accounts/#{subject.id}/following"
      )
    end

    test "mutes walk past the first read", %{subject: subject, others: others} do
      Enum.each(others, fn other ->
        {:ok, _} = Social.follow(subject, other.id)
        Social.set_follow_mute(subject, other, true)
      end)

      assert_walks_everything(mastodon_token(subject, ["read"]), "/api/v1/mutes")
    end

    test "who liked a status walks past the first read", %{subject: subject, others: others} do
      {:ok, post} = Posts.create_post(subject, %{body: "Wer mag das?"})
      Enum.each(others, &Posts.like_post(&1, post))

      assert_walks_everything(
        mastodon_token(subject, ["read"]),
        "/api/v1/statuses/#{post.id}/favourited_by"
      )
    end
  end

  describe "an organization identity" do
    setup do
      Application.put_env(:vutuv, :verify_organization_domains, true)

      on_exit(fn ->
        Application.put_env(:vutuv, :verify_organization_domains, false)
        Application.delete_env(:vutuv, :organizations_dns_resolver)
      end)

      owner = insert(:activated_user)
      organization = active_organization_for(owner)
      {:ok, _} = Organizations.add_role(organization, owner, "publisher", owner)
      {:ok, owner: owner, organization: organization}
    end

    test "walks its own statuses past the first read", %{
      owner: owner,
      organization: organization
    } do
      Enum.each(1..@rows, fn n ->
        {:ok, _} = Posts.create_organization_post(organization, owner, %{body: "Seite #{n}"})
      end)

      assert_walks_everything(
        mastodon_token(owner, ["read"]),
        "/api/v1/accounts/#{organization.id}/statuses"
      )
    end
  end
end
