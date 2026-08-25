defmodule Vutuv.Fediverse.Hashtags do
  @moduledoc """
  Files a cached remote post under the tags its hashtags name, so `/tags/:slug`
  can list what other networks said about a topic (`Vutuv.Tags.Timeline`).

  Two sources, unioned, because the fediverse spells this two ways: the
  ActivityPub `tag` array's `Hashtag` objects (what Mastodon and its relatives
  send, and the same array `Vutuv.RemoteHtml` reads `Mention` objects out of),
  and the `#hashtags` left in the post's own text (servers that send no tag
  objects at all, and the plain-text bodies we store). Neither source is
  authoritative on its own, and both are cheap to read.

  A hashtag naming a topic nobody here has written about yet **mints** it
  (`Vutuv.Tags.tag_ids_for_hashtags/2`, `create: true`). This used to be the one
  hard no in the whole tag catalog, on the grounds that a table a stranger's
  server can extend is a table a stranger's server can flood. What changed is
  the reading of "a stranger": nothing reaches this module unless a member here
  follows the account that sent it — `Vutuv.Fediverse.record_remote_post/2`
  requires an accepted follow before a post is stored at all — so the hashtags
  arriving are the topics our own members chose to read about, not an open
  write. The cost of the old rule was silent and daily: a post about
  `#Eisenach` and `#Thüringen` could be shown but never filed, so vutuv learned
  a topic only when a member typed it into the composer's tag field.

  What still holds the line is in `Vutuv.Tags.tag_ids_for_hashtags/2`: five
  minted tags per post, a slug that has to name the tag, and a page that stays
  `noindex` and out of the sitemap until a **local** member or a **local**
  public post carries it. A remote post can leave a tag page behind; it cannot
  put one in front of a crawler.

  `sync/2` runs on the two paths that can change a post's hashtags — the
  original `Create` and an upstream `Update` — and is idempotent: it inserts
  what is missing and removes filings the edited text no longer carries, so a
  post that drops a hashtag drops off that tag page too.
  """

  import Ecto.Query

  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Fediverse.RemotePostTag
  alias Vutuv.Mentions
  alias Vutuv.Repo
  alias Vutuv.Tags
  alias Vutuv.UUIDv7

  @doc """
  Makes the post's filings match its hashtags, and returns the post unchanged so
  it can sit in an ingestion pipeline.

  `object` is the raw ActivityPub object, read for its `tag` array; the stored
  `content_text` supplies the rest.
  """
  def sync(%RemotePost{} = post, object) do
    wanted =
      post |> names(object) |> Tags.tag_ids_for_hashtags(create: true) |> MapSet.new()

    held = post |> held_tag_ids() |> MapSet.new()

    insert(post, MapSet.difference(wanted, held))
    remove(post, MapSet.difference(held, wanted))

    post
  end

  @doc """
  The hashtag names a post carries: the AP `tag` array's `Hashtag` objects plus
  the `#hashtags` in its stored text, **as written** and deduplicated
  case-insensitively (the first spelling wins).

  The casing survives because these names can now mint a tag, and a tag is
  stored the way whoever names it first wrote it. A remote `#Thüringen` is how
  that topic should read on its own page here; `thüringen` is not.

  Public so a backfill can read the text side of an already-stored post without
  the delivery that brought it.
  """
  def names(%RemotePost{} = post, object \\ %{}) do
    (object_hashtags(object) ++ Mentions.written_hashtags(post.content_text || ""))
    |> Enum.uniq_by(&String.downcase/1)
  end

  # A `Hashtag` in the AP `tag` array carries its name with the `#` still on it
  # ("#Berlin"). Anything else in that array (a `Mention`, an emoji definition)
  # is somebody else's business.
  defp object_hashtags(object) do
    object
    |> Map.get("tag")
    |> List.wrap()
    |> Enum.flat_map(&hashtag_name/1)
  end

  defp hashtag_name(%{"type" => "Hashtag", "name" => name}) when is_binary(name) do
    case name |> String.trim() |> String.trim_leading("#") do
      "" -> []
      tag -> [tag]
    end
  end

  defp hashtag_name(_tag), do: []

  defp held_tag_ids(%RemotePost{id: id}) do
    Repo.all(from(pt in RemotePostTag, where: pt.remote_post_id == ^id, select: pt.tag_id))
  end

  defp insert(%RemotePost{} = post, tag_ids) do
    now = NaiveDateTime.utc_now(:second)

    rows =
      for tag_id <- tag_ids do
        %{
          id: UUIDv7.generate(),
          remote_post_id: post.id,
          tag_id: tag_id,
          inserted_at: now,
          updated_at: now
        }
      end

    # `on_conflict: :nothing` rather than a transaction: the same post is
    # delivered once per follower, and two inboxes racing on the same new filing
    # must not 500 the second one (a sender that gets a 500 retries the whole
    # batch forever).
    if rows != [], do: Repo.insert_all(RemotePostTag, rows, on_conflict: :nothing)
  end

  defp remove(%RemotePost{} = post, tag_ids) do
    ids = MapSet.to_list(tag_ids)

    if ids != [] do
      Repo.delete_all(
        from(pt in RemotePostTag,
          where: pt.remote_post_id == ^post.id and pt.tag_id in ^ids
        )
      )
    end
  end
end
