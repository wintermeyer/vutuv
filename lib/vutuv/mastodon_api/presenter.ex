defmodule Vutuv.MastodonApi.Presenter do
  @moduledoc "Mastodon-compatible JSON representations of vutuv identities and posts."

  alias Phoenix.HTML.Safe
  alias Vutuv.Accounts.User
  alias Vutuv.Avatar
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.MastodonApi
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostImage
  alias Vutuv.UUIDv7
  alias VutuvWeb.Markdown
  alias VutuvWeb.UserHelpers

  def identity_name(%User{} = user),
    do: UserHelpers.full_name(user) <> " (@" <> user.username <> ")"

  def identity_name(%Organization{name: name}), do: name

  def account(%User{} = user) do
    avatar = user_avatar(user)

    base_account(%{
      id: user.id,
      username: user.username,
      acct: user.username,
      display_name: UserHelpers.full_name(user),
      created_at: created_at(user, user.id),
      url: MastodonApi.main_url("/" <> user.username),
      avatar: avatar,
      group: false
    })
  end

  def account(%Organization{} = organization) do
    handle = organization.username || organization.slug
    icon = MastodonApi.main_url("/images/icon-512.png")

    base_account(%{
      id: organization.id,
      username: handle,
      acct: handle,
      display_name: organization.name,
      created_at: created_at(organization, organization.id),
      url: MastodonApi.main_url(Organizations.canonical_path(organization)),
      avatar: icon,
      group: true
    })
  end

  def account(%RemoteAccount{} = account) do
    handle = RemoteAccount.display_handle(account) |> String.trim_leading("@")
    username = handle |> String.split("@") |> hd()
    icon = MastodonApi.main_url("/images/icon-512.png")

    base_account(%{
      id: "remote-" <> account.id,
      username: username,
      acct: handle,
      display_name: account.name || username,
      created_at: timestamp(account.inserted_at),
      url: account.actor_uri,
      avatar: icon,
      group: false
    })
  end

  def status(%Post{} = post) do
    author = Posts.author(post)
    content = post.body |> Markdown.render_post(loaded_images(post)) |> safe_html()

    fields =
      %{
        id: post.id,
        created_at: timestamp(post.inserted_at),
        content: content,
        url: MastodonApi.main_url(Posts.path(post)),
        uri: MastodonApi.main_url(Posts.path(post)),
        account: account(author),
        media_attachments: media_attachments(post)
      }
      |> Map.merge(reply_fields(post))

    base_status(fields)
  end

  def status(%RemotePost{} = post) do
    base_status(%{
      id: "remote-" <> post.id,
      created_at: timestamp(post.published_at),
      content: Markdown.render_remote(post.content_text || ""),
      url: post.origin_url || post.object_uri,
      uri: post.object_uri,
      account: account(post.remote_account),
      sensitive: post.sensitive,
      spoiler_text: post.summary || ""
    })
  end

  def status(%Note{} = note) do
    base_status(%{
      id: "remote-note-" <> note.id,
      created_at: timestamp(note.received_at),
      content: Markdown.render_remote(note.content_text || ""),
      url: Note.origin(note),
      uri: note.object_uri,
      account: note_account(note),
      sensitive: Note.warned?(note),
      spoiler_text: note.summary || "",
      favourites_count: note.likes_count || 0,
      reblogs_count: note.shares_count || 0
    })
  end

  def status_from_entry(%{remote_post: %RemotePost{} = post}), do: status(post)
  def status_from_entry(%{note: %Note{} = note}), do: status(note)
  def status_from_entry(%{post: %Post{} = post}), do: status(post)

  defp base_account(fields) do
    Map.merge(
      %{
        locked: false,
        bot: false,
        discoverable: true,
        group: false,
        note: "",
        header: MastodonApi.main_url("/images/icon-512.png"),
        header_static: MastodonApi.main_url("/images/icon-512.png"),
        avatar_static: fields.avatar,
        followers_count: 0,
        following_count: 0,
        statuses_count: 0,
        last_status_at: nil,
        noindex: false,
        emojis: [],
        roles: [],
        fields: []
      },
      fields
    )
  end

  defp base_status(fields) do
    Map.merge(
      %{
        in_reply_to_id: nil,
        in_reply_to_account_id: nil,
        reblog: nil,
        sensitive: false,
        spoiler_text: "",
        visibility: "public",
        language: nil,
        replies_count: 0,
        reblogs_count: 0,
        favourites_count: 0,
        edited_at: nil,
        media_attachments: [],
        mentions: [],
        tags: [],
        emojis: [],
        card: nil,
        poll: nil,
        favourited: false,
        reblogged: false,
        muted: false,
        bookmarked: false,
        pinned: false,
        application: nil,
        filtered: []
      },
      fields
    )
  end

  defp user_avatar(user) do
    case Avatar.display_url(user, :thumb) do
      "/" <> _path = relative -> MastodonApi.main_url(relative)
      "data:" <> _placeholder -> MastodonApi.main_url("/images/icon-512.png")
      absolute -> absolute
    end
  end

  defp note_account(%Note{account_id: id} = note) when is_binary(id) do
    case Fediverse.get_remote_account(id) do
      %RemoteAccount{} = remote_account -> account(remote_account)
      nil -> note_fallback_account(note)
    end
  end

  defp note_account(note), do: note_fallback_account(note)

  defp note_fallback_account(note) do
    handle = Note.display_handle(note) |> String.trim_leading("@")
    username = handle |> String.split("@") |> hd()
    icon = MastodonApi.main_url("/images/icon-512.png")

    id = :crypto.hash(:sha256, note.actor_uri) |> Base.url_encode64(padding: false)

    base_account(%{
      id: "remote-note-author-" <> id,
      username: username,
      acct: handle,
      display_name: note.display_name || username,
      created_at: timestamp(note.received_at),
      url: note.actor_uri,
      avatar: icon,
      group: false
    })
  end

  defp reply_fields(post) do
    case Posts.reply_ref_state(post) do
      {:parent, %Post{} = parent} ->
        %{in_reply_to_id: parent.id, in_reply_to_account_id: account(Posts.author(parent)).id}

      _not_a_live_parent ->
        %{}
    end
  end

  @doc """
  One freshly uploaded picture, for the media endpoints.

  A vutuv upload is never instantly usable: the AI image scan runs first and
  the row starts `pending`. Mastodon's own vocabulary already has that state —
  a `url` of `null` means "still processing, poll me" — so an unreleased image
  is rendered exactly that way rather than handing out a link to something no
  reader may see yet.
  """
  def media_attachment(%PostImage{} = image) do
    attachment = post_attachment(image)

    if ImageScans.released?(image.moderation),
      do: attachment,
      else: %{attachment | url: nil, preview_url: nil}
  end

  @doc "Whether the scan has finished with this picture, either way."
  def media_ready?(%PostImage{} = image), do: ImageScans.released?(image.moderation)

  # An unloaded association is truthy, so `post.images || []` survived the `||`
  # and then failed `render_post/3`'s `is_list` guard, whose catch-all answers
  # an empty body — a status with **no text at all**, silently. Every caller
  # inside this adapter preloads, but `Vutuv.Search` does not, and the search
  # endpoint duly served blank posts. A missing preload may cost the inline
  # pictures; it must never cost the words.
  defp loaded_images(%Post{images: images}) when is_list(images), do: images
  defp loaded_images(_not_loaded), do: []

  defp media_attachments(post) do
    post |> Posts.released_images() |> Enum.map(&post_attachment/1)
  end

  defp post_attachment(%PostImage{} = image) do
    %{
      id: image.id,
      type: "image",
      url: image_url(image, "large"),
      preview_url: image_url(image, "feed"),
      remote_url: nil,
      preview_remote_url: nil,
      text_url: nil,
      meta: %{original: %{width: image.width, height: image.height}},
      description: image.alt || "",
      blurhash: nil
    }
  end

  defp image_url(%PostImage{} = image, version),
    do: MastodonApi.main_url(PostImage.url(image, version))

  defp safe_html(value), do: value |> Safe.to_iodata() |> IO.iodata_to_binary()

  defp timestamp(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)

  # Not every caller hands over a fully loaded row: `Vutuv.Search` selects the
  # few columns a result list needs, so `inserted_at` can be absent. Raising
  # over a missing display timestamp would be the wrong trade, and there is a
  # better answer than nil — the id is a UUIDv7 and carries its own creation
  # time.
  defp timestamp(_missing), do: nil

  defp created_at(%{inserted_at: at}, _id) when not is_nil(at), do: timestamp(at)
  defp created_at(_record, id), do: timestamp(UUIDv7.timestamp(id))
end
