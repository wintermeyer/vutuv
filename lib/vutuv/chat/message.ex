defmodule Vutuv.Chat.Message do
  @moduledoc false

  use VutuvWeb, :model

  alias Vutuv.MarkdownContent

  @max_body_length 10_000

  schema "messages" do
    field(:body, :string)
    # Set while the message is in the moderation freezer: hidden from the
    # other participant. Managed by Vutuv.Moderation, never cast.
    field(:frozen_at, :naive_datetime)

    belongs_to(:conversation, Vutuv.Chat.Conversation)
    # Nullable: a deleted sender's messages survive for the other participant.
    belongs_to(:sender, Vutuv.Accounts.User)

    # Microsecond precision (not the default second) so the read marker
    # `max(inserted_at)` can distinguish a message arriving in the same
    # wall-clock second as a read — issue #776 (4b).
    timestamps(type: :naive_datetime_usec)
  end

  def max_body_length, do: @max_body_length

  def changeset(message, params \\ %{}) do
    message
    |> cast(params, [:body])
    |> update_change(:body, &String.trim/1)
    |> validate_required([:body])
    |> validate_length(:body, max: @max_body_length)
    # Messages carry no images: the renderer also drops any `<img>` at display
    # time (`VutuvWeb.Markdown.render/1`); this is the storage-side guard.
    |> MarkdownContent.validate_no_images()
  end
end
