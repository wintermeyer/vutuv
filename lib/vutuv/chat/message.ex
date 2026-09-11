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

  defp require_body(changeset, false), do: validate_required(changeset, [:body])

  defp require_body(changeset, true) do
    case get_field(changeset, :body) do
      body when is_binary(body) and body != "" -> changeset
      _blank -> put_change(changeset, :body, "")
    end
  end
end
