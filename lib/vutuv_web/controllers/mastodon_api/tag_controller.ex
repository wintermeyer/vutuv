defmodule VutuvWeb.MastodonApi.TagController do
  @moduledoc """
  Mastodon's hashtag endpoints, mapped onto vutuv's topics.

  vutuv has had tag following since issue #872 — a private subscription that
  pulls a topic's posts into the member's `/feed`, with no owner to notify and
  no public follower list — which is Mastodon's followed hashtag down to the
  silence. The adapter nevertheless answered `/api/v1/followed_tags` with a
  hardcoded empty list and had no follow route at all, so a client showed the
  member no tags, offered "Follow" on a topic they already followed, and 404ed
  when they pressed it.

  A **page identity** cannot act here. vutuv does let a page follow a topic
  (`Tags.follow_tag_as_organization/2`), but Mastodon has no notion of posting
  as somebody else, so a client acting for a page has no way to say which of the
  two it means — and silently subscribing the member instead is the wrong guess
  in the direction that is hardest to notice. It answers 422, the same refusal
  the account relationships use for an action an identity cannot perform.
  """

  use VutuvWeb, :controller

  import VutuvWeb.MastodonApi.Errors

  alias Vutuv.MastodonApi.Presenter
  alias Vutuv.Organizations.Organization
  alias Vutuv.Tags
  alias Vutuv.Tags.Tag
  alias VutuvWeb.MastodonApi.Pagination

  @doc """
  One topic (`GET /api/v1/tags/:id`).

  The `:id` a client sends is the hashtag as written, so it is matched by slug —
  and through an alias to the topic it was merged into (#1338), because a client
  holding an old spelling should land on the topic rather than on a dead end.
  """
  def show(conn, %{"id" => id}) do
    case topic(id) do
      %Tag{} = tag -> json(conn, Presenter.tag(tag, following?(conn, tag)))
      nil -> not_found(conn)
    end
  end

  def follow(conn, %{"id" => id}), do: subscribe(conn, id, :follow)
  def unfollow(conn, %{"id" => id}), do: subscribe(conn, id, :unfollow)

  @doc """
  The topics this member follows (`GET /api/v1/followed_tags`).

  A **page**, like every other list here: Mastodon's own is one, and a member
  following several hundred topics would otherwise get the lot in one body.
  The cursor is the subscription row's id rather than the tag's — that is what
  orders the list (most recently followed first) and the ids are UUID v7, so
  the order the client walks is the order it was shown. The `Link` header
  carries it; the Tag entity has no id field to put it in, which is exactly how
  Mastodon paginates this endpoint too.
  """
  def followed(%{assigns: %{current_organization: %Organization{}}} = conn, _params),
    do: json(conn, [])

  def followed(conn, params) do
    page = Pagination.params(params)

    rows =
      conn.assigns.current_user
      |> Tags.followed_tags_page(Pagination.opts(page))
      |> Pagination.reverse(page)

    conn
    |> Pagination.link_header(Enum.map(rows, &elem(&1, 0)), page)
    # `true` by construction — every tag this list returns is one the member
    # follows — so there is nothing to look up per row.
    |> json(Enum.map(rows, fn {_follow_id, tag} -> Presenter.tag(tag, true) end))
  end

  # A page identity is refused before anything is looked up: vutuv does let a
  # page follow a topic (`Tags.follow_tag_as_organization/2`), but Mastodon has
  # no notion of acting as somebody else, so a client acting for a page has no
  # way to say which of the two it means — and quietly subscribing the member
  # instead is the wrong guess in the direction hardest to notice.
  defp subscribe(%{assigns: %{current_organization: %Organization{}}} = conn, _id, _action),
    do: unsupported(conn)

  defp subscribe(conn, id, action) do
    with %Tag{} = tag <- topic(id),
         :ok <- apply_subscription(conn.assigns.current_user, tag, action) do
      # The answer states the outcome the action just decided, rather than
      # asking the database to confirm it: a client flips its button back on
      # the next read if the reply disagrees. Which is why the outcome has to
      # be the real one — a topic merged or deleted between the lookup and the
      # insert answered 200 and `following: true` for a subscription that does
      # not exist, and the button stayed lit until a full refresh.
      json(conn, Presenter.tag(tag, action == :follow))
    else
      _gone -> not_found(conn)
    end
  end

  defp apply_subscription(user, tag, :follow) do
    case Tags.follow_tag(user, tag) do
      {:ok, _follow} -> :ok
      {:error, _reason} -> :error
    end
  end

  # A count of 0 is not a failure: unfollowing what you do not follow is the
  # state the client asked for.
  defp apply_subscription(user, tag, :unfollow) do
    Tags.unfollow_tag(user, tag)
    :ok
  end

  # A client sends the hashtag as the member wrote it and vutuv's slugs are
  # lower case, so this downcases exactly as `/api/v1/timelines/tag/:hashtag`
  # does — the two halves of one gesture, the timeline and the Follow button
  # beside it, must not disagree about what `#Elixir` names.
  defp topic(id) when is_binary(id), do: id |> String.downcase() |> Tags.resolve_tag_by_slug()
  defp topic(_id), do: nil

  # `show/2` is the one read that has to ask, because nothing about the request
  # says whether this member already follows the topic.
  defp following?(%{assigns: %{current_organization: %Organization{}}}, _tag), do: false
  defp following?(conn, tag), do: Tags.tag_followed?(conn.assigns.current_user, tag)
end
