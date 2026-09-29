defmodule Vutuv.Fediverse.PostRemoteMention do
  @moduledoc """
  An account on another network that a post of ours names as `@user@host`.

  Written from the body whenever the post is saved
  (`Vutuv.Fediverse.sync_remote_mentions/1`), resolved off the request path,
  and read in three places once `remote_account_id` is set: the Note's `tag`
  array carries a `Mention` for it (the person's server notifies them), their
  inbox joins the post's recipients, and the purge of unreferenced accounts
  spares their row, which keeps the mention's link on their real profile page.

  An unresolved row (`remote_account_id` NULL) is the resolution's own state.
  `attempts` and `attempted_at` are the sweeper's clock, stamped on every try
  whatever it answers, so an address that cannot be resolved stops being due
  instead of holding the front of every batch.
  """

  use VutuvWeb, :model

  # `user@host`: a 64-byte handle, the separator and a 253-byte host, rounded.
  @max_address 320

  schema "post_remote_mentions" do
    belongs_to(:post, Vutuv.Posts.Post)
    belongs_to(:remote_account, Vutuv.Fediverse.RemoteAccount)

    field(:address, :string)
    field(:attempts, :integer, default: 0)
    field(:attempted_at, :utc_datetime)

    timestamps()
  end

  @doc "The longest address a row may carry."
  def max_address, do: @max_address
end
