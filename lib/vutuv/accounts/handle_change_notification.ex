defmodule Vutuv.Accounts.HandleChangeNotification do
  @moduledoc """
  A durable "@old renamed to @new" notification for one affected post author.

  Unlike every other kind in the derived `Vutuv.Activity` feed — which reflects
  only *current* state — this records a point-in-time fact (the old handle is
  gone the moment the rename commits) plus the ids of the recipient's posts
  whose `@old` mentions were rewritten to `@new`. `Vutuv.Activity` reads these
  rows directly to build the feed item and count it toward the unread badge.
  """
  use VutuvWeb, :model

  alias Vutuv.Accounts.User

  schema "handle_change_notifications" do
    field(:old_handle, :string)
    field(:new_handle, :string)
    field(:post_ids, {:array, :binary_id}, default: [])
    belongs_to(:recipient, User)
    belongs_to(:actor, User)

    timestamps(updated_at: false)
  end

  @doc """
  Builds an insert changeset. The owner FKs (`recipient_id`, `actor_id`) are set
  on the struct by the caller, never cast, since they come from the rename, not
  from user input.
  """
  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [:old_handle, :new_handle, :post_ids])
    |> validate_required([:recipient_id, :actor_id, :old_handle, :new_handle])
  end
end
