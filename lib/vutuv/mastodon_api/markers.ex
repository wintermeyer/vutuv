defmodule Vutuv.MastodonApi.Markers do
  @moduledoc """
  Where a client left off reading, per identity and timeline —
  Mastodon's `/api/v1/markers`.

  The endpoint answered `{}` and had no `POST`, so a position was never stored
  and never restored: relaunching an app dropped its timeline back to whatever
  it could fetch. It is the client's own bookmark, not a read receipt — vutuv's
  own unread marker (`users.notifications_read_at`) stays what the website uses,
  and the two are deliberately not wired together: a member scrolling past a
  notification in a phone app has not read it on the website, and one surface
  silently marking another's badge away is a worse answer than two honest ones.

  `last_read_id` is stored as the client sent it, prefix and all. A Mastodon id
  here can be a vutuv uuid or one of the derived ids this adapter mints
  (`remote-<uuid>`, `like-<uuid>`), and validating it against a row would fail
  a write for the one case that must not fail: a bookmark whose entry is since
  gone. It scrolls to nothing, which is what a bookmark into a deleted post does
  everywhere.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.MastodonApi.Marker
  alias Vutuv.Organizations.Organization
  alias Vutuv.Repo

  @timelines ~w(home notifications)

  @doc "The timelines Mastodon defines a marker for; anything else is ignored."
  def timelines, do: @timelines

  @doc """
  The identity's markers as a map of `timeline => %Marker{}`.

  `only` narrows to the timelines a client asked for (`timeline[]=home`); an
  empty or missing list answers everything. Mastodon answers `{}` there
  (`where(timeline: Array(params[:timeline]))` over an empty array), which is
  an accident of its query rather than a shape a client depends on — every one
  of them names the timelines it wants, and answering the lot is the more
  useful reading of "no filter".
  """
  def get(identity, only \\ []) do
    wanted = Enum.filter(only, &(&1 in @timelines))
    wanted = if wanted == [], do: @timelines, else: wanted

    identity
    |> scope()
    |> where([m], m.timeline in ^wanted)
    |> Repo.all()
    |> Map.new(&{&1.timeline, &1})
  end

  @doc """
  Records a position. Returns the stored markers for the timelines it wrote.

  Mastodon's shape is `home[last_read_id]=…`, so `params` is that outer map.
  Unknown timelines and blank ids are skipped rather than refused: a client
  sending one of each in the same request must still get its good half stored.
  """
  def put(identity, params) when is_map(params) do
    @timelines
    |> Enum.flat_map(fn timeline ->
      case last_read_id(params[timeline]) do
        nil -> []
        id -> [{timeline, upsert!(identity, timeline, id)}]
      end
    end)
    |> Map.new()
  end

  defp last_read_id(%{"last_read_id" => id}) when is_binary(id) do
    case String.trim(id) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, 255)
    end
  end

  defp last_read_id(_absent), do: nil

  # `version` counts writes, the way Mastodon's does, so a client can tell its
  # own echo from somebody else's write on another device.
  #
  # One statement rather than a read and then a write: two of a member's own
  # devices posting a position in the same instant both saw no row and both
  # inserted, and the loser met the unique index as an `Ecto.ConstraintError` —
  # a 500 on exactly the several-installs case this endpoint exists for.
  # `conflict_target` has to repeat each index's `WHERE`, because both are
  # partial; Postgres cannot infer a partial index without its predicate.
  #
  # The member half of that race has **no test**, deliberately: reproducing it
  # needs two connections stopped between their read and their write, and a
  # test that merely writes twice passes against the old code too. The page
  # half is covered, because there the same collision is reachable without a
  # race at all — two publishers, one position (`markers_test.exs`).
  defp upsert!(identity, timeline, last_read_id) do
    identity
    |> new_marker()
    |> Map.merge(%{timeline: timeline, last_read_id: last_read_id})
    |> Repo.insert!(
      on_conflict: [
        set: [last_read_id: last_read_id, updated_at: NaiveDateTime.utc_now(:second)],
        inc: [version: 1]
      ],
      conflict_target: conflict_target(identity),
      returning: true
    )
  end

  # A page's row keeps the `user_id` of whoever wrote it first: the position is
  # the page's, and the column only records where it came from.
  defp conflict_target(%User{}),
    do: {:unsafe_fragment, "(user_id, timeline) WHERE organization_id IS NULL"}

  defp conflict_target({%User{}, %Organization{}}),
    do: {:unsafe_fragment, "(organization_id, timeline) WHERE organization_id IS NOT NULL"}

  defp new_marker(%User{id: user_id}), do: %Marker{user_id: user_id}

  defp new_marker({%User{id: user_id}, %Organization{id: organization_id}}),
    do: %Marker{user_id: user_id, organization_id: organization_id}

  # An organization identity's marker is the page's, not the member's: two
  # publishers reading the page from their own phones share one position, the
  # same way they share the page's feed.
  defp scope(%User{id: user_id}),
    do: from(m in Marker, where: m.user_id == ^user_id and is_nil(m.organization_id))

  defp scope({%User{}, %Organization{id: organization_id}}),
    do: from(m in Marker, where: m.organization_id == ^organization_id)
end
