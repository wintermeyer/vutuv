defmodule Vutuv.Tags do
  @moduledoc """
  The Tags context: adding tags to users (one name or a comma-separated
  batch — registration and the tags page share this path) and user tag
  endorsements.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Repo
  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.UserTag
  alias Vutuv.Tags.UserTagEndorsement

  # The endorsers list: which columns it can be sorted by, and a denser page
  # size than the site-wide default so a popular tag's list actually paginates.
  @endorser_sorts ~w(name username date)
  @endorsers_per_page 25

  @doc """
  Splits a comma-separated tag string into clean names: `" PHP, , Go "` →
  `["PHP", "Go"]`. Safe to call with `nil` (returns `[]`).
  """
  def parse_tag_names(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def parse_tag_names(_), do: []

  @doc """
  Tags `user` with `name`, creating the global tag or linking the existing
  one. Returns the `Repo.insert` result; a duplicate or invalid name comes
  back as `{:error, changeset}`.
  """
  def add_user_tag(%User{} = user, name) when is_binary(name) do
    user
    |> Ecto.build_assoc(:user_tags, %{})
    |> UserTag.changeset()
    |> Tag.create_or_link_tag(%{"value" => name})
    |> Repo.insert()
  end

  @doc """
  Given candidate tag slugs (the `#hashtags` in a Markdown body), returns the
  `MapSet` of those naming a real tag with **at least one visible member** — a
  confirmed, non-hidden user carries the tag, so its `/tags/:slug` page actually
  shows something. Powers the hashtag links `VutuvWeb.Markdown` writes; an
  unknown or empty tag is absent from the set, so it stays plain text. The
  visible-member gate is the same one the tag page lists by
  (`Tag.recommended_users/1`). One query; an empty input skips the DB so the
  renderer's no-hashtag path stays query-free.
  """
  def linkable_slugs(slugs) when is_list(slugs) do
    import Vutuv.Moderation.Query, only: [account_hidden: 1, account_confirmed_row: 1]

    case slugs |> Enum.map(&String.downcase/1) |> Enum.uniq() do
      [] ->
        MapSet.new()

      normalized ->
        from(t in Tag,
          join: ut in assoc(t, :user_tags),
          join: u in assoc(ut, :user),
          where: t.slug in ^normalized,
          where: account_confirmed_row(u) and not account_hidden(u.id),
          distinct: true,
          select: t.slug
        )
        |> Repo.all()
        |> MapSet.new()
    end
  end

  @doc """
  Endorse a user's tag. The chokepoint for endorsements: besides inserting the
  row it pushes the live in-app notification to the tag's owner, so all
  endorsement paths must come through here (not a raw `Repo.insert`).
  """
  def create_endorsement(attrs) do
    result = %UserTagEndorsement{} |> UserTagEndorsement.changeset(attrs) |> Repo.insert()

    with {:ok, endorsement} <- result do
      # notify_endorsement preloaded the owner already, so reuse the id it
      # returns for the live-count broadcast instead of re-querying it.
      broadcast_endorsement_changed(notify_endorsement(endorsement), endorsement.user_tag_id)
    end

    result
  end

  @doc """
  Removes `user_id`'s endorsement of `user_tag_id`. Returns the number of rows
  deleted (0 or 1), so an undo of an endorsement that is already gone is a
  no-op rather than a raise (the profile's upvote pill toggles idempotently).
  """
  def delete_endorsement(user_tag_id, user_id) do
    {count, _} =
      from(e in UserTagEndorsement,
        where: e.user_tag_id == ^user_tag_id and e.user_id == ^user_id
      )
      |> Repo.delete_all()

    if count > 0 do
      owner_id = Repo.one(from(ut in UserTag, where: ut.id == ^user_tag_id, select: ut.user_id))
      broadcast_endorsement_changed(owner_id, user_tag_id)
    end

    count
  end

  @doc "Whether `user_id` currently endorses `user_tag_id`."
  def endorsed?(user_tag_id, user_id) do
    Repo.exists?(
      from(e in UserTagEndorsement,
        where: e.user_tag_id == ^user_tag_id and e.user_id == ^user_id
      )
    )
  end

  @doc """
  Number of *currently-visible* endorsers of `user_tag_id` (the public count
  shown on the upvote pill). Goes through `UserTagEndorsement.visible/1`, so a
  hidden or never-activated endorser never inflates the tally (issue #783).
  """
  def count_visible_endorsements(user_tag_id) do
    UserTagEndorsement.visible()
    |> where([e], e.user_tag_id == ^user_tag_id)
    |> Repo.aggregate(:count)
  end

  @doc """
  One page of the *currently-visible* endorsers of `user_tag`, newest first.

  Backs the public endorser list (`/:slug/tags/:tag/endorsers`, the profile
  Tags popover's "and N more" link). Goes through
  `UserTagEndorsement.visible_with_endorser/1`, so hidden / unconfirmed
  endorsers are neither listed nor counted (issue #783), and is offset
  paginated by `Vutuv.Pages.paginate/3` like the follower / connection lists.
  The list is sortable from `params`: `"sort"` is one of `name` (last name
  then first name), `username` (the `username`) or `date` (the endorsement
  itself), and `"dir"` is `"asc"`/`"desc"`. Default is `date` descending —
  newest endorser first — and `e.id` (a time-ordered UUID v7) is the stable
  tiebreaker for every sort. Offset paginated at `endorsers_per_page/0` (a
  denser page than the site-wide default, so a long list actually paginates).

  Returns `%{users: [...], total: total, endorsed_at: %{user_id =>
  inserted_at}, sort: sort, dir: dir}` — `endorsed_at` carries when each
  listed endorser cast their vote (the per-row timestamp); `sort`/`dir` are
  the normalized values the page renders its sort controls from.
  """
  def endorsers_page(%UserTag{} = user_tag, params) do
    total = count_visible_endorsements(user_tag.id)
    {sort, dir} = endorser_sort(params)

    endorsements =
      UserTagEndorsement.visible_with_endorser()
      |> where([e], e.user_tag_id == ^user_tag.id)
      |> endorser_order(sort, dir)
      |> Vutuv.Pages.paginate(params, total, @endorsers_per_page)
      |> Repo.all()

    %{
      users: Enum.map(endorsements, & &1.user),
      total: total,
      endorsed_at: Map.new(endorsements, &{&1.user_id, &1.inserted_at}),
      sort: sort,
      dir: dir
    }
  end

  @doc "Rows per page of the endorsers list (shared by the query and the pager)."
  def endorsers_per_page, do: @endorsers_per_page

  # Normalize the sort params, defaulting to newest-endorser-first.
  defp endorser_sort(params) do
    sort = if params["sort"] in @endorser_sorts, do: params["sort"], else: "date"
    dir = if params["dir"] in ~w(asc desc), do: params["dir"], else: default_dir(sort)
    {sort, dir}
  end

  defp default_dir("date"), do: "desc"
  defp default_dir(_sort), do: "asc"

  # Order the endorsements; `u` is the endorser joined in by visible_with_endorser/0.
  # e.id (UUID v7 = creation order) is the stable tiebreaker on every sort.
  defp endorser_order(query, "name", dir) do
    d = dir_atom(dir)
    order_by(query, [e, u], [{^d, u.last_name}, {^d, u.first_name}, desc: e.id])
  end

  defp endorser_order(query, "username", dir) do
    d = dir_atom(dir)
    order_by(query, [e, u], [{^d, u.username}, desc: e.id])
  end

  defp endorser_order(query, "date", dir) do
    order_by(query, [e], [{^dir_atom(dir), e.id}])
  end

  defp dir_atom("asc"), do: :asc
  defp dir_atom(_dir), do: :desc

  defp notify_endorsement(endorsement) do
    %{user_tag: %{user_id: owner_id, tag: tag}} =
      Repo.preload(endorsement, user_tag: :tag)

    # Endorsing your own tag is possible but not news.
    if owner_id != endorsement.user_id do
      endorser = Repo.get(Vutuv.Accounts.User, endorsement.user_id)
      Vutuv.Activity.notify_endorsement(owner_id, endorser, tag.name)
    end

    owner_id
  end

  # Tell the tag owner's open profile to re-render the affected pill's count and
  # roster live, so an endorse / unendorse shows even on a different page or when
  # made by another member. `VutuvWeb.UserProfileLive` listens for
  # `:endorsement_changed`; other subscribers ignore it (catch-all handle_info).
  defp broadcast_endorsement_changed(owner_id, user_tag_id) do
    Vutuv.Activity.broadcast(owner_id, {:endorsement_changed, user_tag_id})
  end
end
