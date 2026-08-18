defmodule Vutuv.MastodonApi.AccountCounts do
  @moduledoc """
  The three profile-header figures for a whole page of accounts at once.

  **Mastodon fills these on every account it sends, everywhere**, because on its
  side they are counter columns on the accounts table — a client therefore reads
  them off whatever account object it happens to hold, typically the one
  embedded in a status it already has, and refreshes the profile only later. Our
  adapter filled them on the two endpoints that answer with a *single* account
  and left them at the entity's zeroes everywhere else, which is not "no data" to
  a client: it is the number zero. A member with a full timeline saw "0 posts" in
  their own profile header, and tapping it listed all of them.

  Each figure is one query for the whole page rather than one per row, because
  every one of them is a real aggregate here:

    * followers and following come from `Vutuv.Social`'s own gated queries (the
      batched twins of the single counts, sharing their scope so the two cannot
      disagree), plus the accounts a member follows on other networks;
    * the status count is `Vutuv.Posts.author_post_counts/2` — the same
      viewer-scoped timeline the profile endpoint counts, so the figure a client
      reads in a timeline is the figure it reads on the profile.

  Pages are counted one at a time instead: a page authoring posts is the rare row
  in a timeline, its counts have no grouped query today, and writing one for a
  handful of rows would buy nothing. Remote accounts get no counts at all — we
  cache their posts, not their social graph, and a number invented from what
  happens to be cached would be worse than the honest zero.
  """

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias Vutuv.Posts
  alias Vutuv.Social
  alias Vutuv.UUIDv7

  @doc """
  `%{account_id => %{followers:, following:, statuses:}}` for every account the
  rendered `statuses` embed.

  Takes the rendered statuses rather than the records behind them: one page can
  carry members, pages and remote actors, each reached through a different
  association, and the rendered account already says which kind it is.
  """
  def for_statuses(statuses, viewer) when is_list(statuses) do
    {pages, members} =
      statuses
      |> Enum.flat_map(&embedded_accounts/1)
      |> Enum.uniq_by(& &1.id)
      |> Enum.split_with(& &1.group)

    reader = reader(viewer)

    Map.merge(member_counts(local_ids(members), reader), page_counts(local_ids(pages), reader))
  end

  # **The acting identity is not always a person, and the visibility queries take
  # a person or nobody.** `Vutuv.Posts.scope_visible/2` has exactly two clauses,
  # `nil` and `%User{}`, so handing it the `%Organization{}` a page identity acts
  # as raises rather than narrowing — which is what a client acting for a page
  # got out of its home timeline the moment this started counting. Reading a
  # profile *as* a page is anonymous reading, the same call the single-account
  # endpoint makes (`AccountController.profile_viewer/1`), so a page identity
  # counts what a stranger would see.
  defp reader(%User{} = user), do: user
  defp reader(_page_or_nobody), do: nil

  # A remote actor's id carries a prefix (`remote-<uuid>`, `remote-note-author-…`)
  # and so is not a bare uuid — which is exactly what marks it as somebody whose
  # figures are not ours to state.
  defp local_ids(accounts) do
    for %{id: id} <- accounts, uuid = UUIDv7.cast_or_nil(id), do: uuid
  end

  defp member_counts([], _viewer), do: %{}

  defp member_counts(ids, viewer) do
    followers = Social.follower_counts(ids)
    followees = Social.followee_counts(ids)
    remote = Fediverse.remote_follow_counts(ids)
    statuses = Posts.author_post_counts(ids, viewer)

    Map.new(ids, fn id ->
      {id,
       %{
         followers: Map.get(followers, id, 0),
         following: Map.get(followees, id, 0) + Map.get(remote, id, 0),
         statuses: Map.get(statuses, id, 0)
       }}
    end)
  end

  defp page_counts([], _viewer), do: %{}

  defp page_counts(ids, viewer) do
    ids
    |> Enum.map(&Organizations.get_organization/1)
    |> Enum.reject(&is_nil/1)
    |> Map.new(fn %Organization{} = page ->
      {page.id,
       %{
         followers: Social.organization_follower_count(page),
         following:
           Social.organization_followee_count(page) +
             length(Fediverse.list_organization_remote_follows(page)),
         statuses: Posts.count_organization_posts(page, viewer)
       }}
    end)
  end

  # A reshare carries two accounts — whoever passed the post on, and its author —
  # and a client renders a profile header from either.
  defp embedded_accounts(%{account: account, reblog: %{account: inner}}), do: [account, inner]
  defp embedded_accounts(%{account: account}), do: [account]
  defp embedded_accounts(_no_account), do: []
end
