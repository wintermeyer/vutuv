defmodule Vutuv.Fediverse.PrivateMessage do
  @moduledoc "An outgoing private text message. Post and parent references are optional; the reply workflow supplies both."
  use VutuvWeb, :model

  schema "fediverse_private_messages" do
    field(:body, :string)
    field(:object_uri, :string)
    field(:in_reply_to_uri, :string)
    field(:recipient_actor_uri, :string)
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:post, Vutuv.Posts.Post)
    timestamps()
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:body])
    |> update_change(:body, &String.trim/1)
    |> validate_required([:body])
    |> validate_length(:body, max: 5000)
    |> validate_format(:body, ~r/\A[^\x00]*\z/u)
  end
end
