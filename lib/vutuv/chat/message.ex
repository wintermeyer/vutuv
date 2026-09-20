defmodule Vutuv.Chat.Message do
  @moduledoc false

  use VutuvWeb, :model

  alias Vutuv.MarkdownContent
  alias Vutuv.Mentions

  @max_body_length 10_000

  schema "messages" do
    field(:body, :string)
    # Set while the message is in the moderation freezer: hidden from the
    # other participant. Managed by Vutuv.Moderation, never cast.
    field(:frozen_at, :naive_datetime)

    belongs_to(:conversation, Vutuv.Chat.Conversation)
    # Nullable: a deleted sender's messages survive for the other participant.
    belongs_to(:sender, Vutuv.Accounts.User)
    # Sent in a page's name (issue #1336), with the member who wrote it kept
    # internally — the same split `posts` uses for authorship: the message
    # belongs to the page, so it must not leave with the person who typed it.
    belongs_to(:sender_organization, Vutuv.Organizations.Organization)
    belongs_to(:acting_user, Vutuv.Accounts.User)

    # Written on another network and delivered to this member. The third
    # sender kind, beside the member and the page; nilified rather than
    # cascaded, so blocking a server does not take the member's own record of
    # what was said with it.
    belongs_to(:sender_remote_account, Vutuv.Fediverse.RemoteAccount)

    # The same words where they also live: a private answer under a post is a
    # note, a sent one is an outgoing private message. Both keep rendering
    # under the post; these links are what lets the two views point at each
    # other. `ON DELETE SET NULL`, because a note expires after 183 days while
    # the conversation is the member's own mail and stays.
    belongs_to(:note, Vutuv.Fediverse.Note)
    belongs_to(:private_message, Vutuv.Fediverse.PrivateMessage)

    # The incoming activity's AP id, so a redelivery cannot store a second
    # copy (unique). A plain DM has no note row to carry it.
    field(:remote_object_uri, :string)

    # The files and pictures hanging beside the text (issue #2110), only ever
    # between two connected members. They are attachments, not images: the body
    # itself stays image-free (`validate_no_images/2` below).
    has_many(:attachments, Vutuv.Attachments.Attachment)

    # Microsecond precision (not the default second) so the read marker
    # `max(inserted_at)` can distinguish a message arriving in the same
    # wall-clock second as a read — issue #776 (4b).
    timestamps(type: :naive_datetime_usec)
  end

  def max_body_length, do: @max_body_length

  @doc """
  The insert. `files?: true` says the message carries at least one attachment
  (issue #2110), which is what lets the body be empty: sending a picture with
  nothing written under it is the ordinary case, and refusing it would be a
  defect. The column is `NOT NULL`, so such a body is stored as the empty
  string — `cast/3` treats `""` as absent, hence the explicit change.
  """
  def changeset(message, params \\ %{}, opts \\ []) do
    message
    |> cast(params, [:body])
    |> update_change(:body, &String.trim/1)
    |> require_body(Keyword.get(opts, :files?, false))
    |> validate_length(:body, max: @max_body_length)
    # Messages carry no images: the renderer also drops any `<img>` at display
    # time (`VutuvWeb.Markdown.render/1`); this is the storage-side guard.
    |> MarkdownContent.validate_no_images()
    # A DM may only mention handles that exist (kept clean like a post body).
    |> Mentions.validate_mentions_exist()
  end

  @doc """
  A message written on another network.

  Deliberately not `changeset/3`: the text is a stranger's, already reduced to
  plain text at the inbox (`Vutuv.RemoteHtml.to_text/3`), so the two checks
  that belong to *our* composer would refuse it for the wrong reasons — a
  mention of a handle that only exists on their server is not a broken
  mention, and an image the renderer drops at display time anyway is not a
  reason to throw a member's mail away. What stays is the ceiling: the column
  is `text`, but an unbounded body has no place in a sidebar preview or an
  email, so an over-long one is cut rather than refused (refusing would mean
  the member never learns they were written to).
  """
  def remote_changeset(message, params) do
    message
    |> cast(params, [:body, :remote_object_uri])
    |> update_change(:body, &String.trim/1)
    |> update_change(:body, &truncate/1)
    |> validate_required([:body])
    |> unique_constraint(:remote_object_uri)
  end

  defp truncate(body) when is_binary(body) do
    if String.length(body) > @max_body_length,
      do: String.slice(body, 0, @max_body_length),
      else: body
  end

  defp truncate(body), do: body

  defp require_body(changeset, false), do: validate_required(changeset, [:body])

  defp require_body(changeset, true) do
    case get_field(changeset, :body) do
      body when is_binary(body) and body != "" -> changeset
      _blank -> put_change(changeset, :body, "")
    end
  end
end
