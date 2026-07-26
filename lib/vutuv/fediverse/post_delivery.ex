defmodule Vutuv.Fediverse.PostDelivery do
  @moduledoc """
  One record of "this post went to that inbox, under this Note id" (issue #1102)
  — the address book a **revocation** needs.

  Written when a `Create`/`Update` is enqueued, read when the post is taken
  down. It answers the two questions a `Delete(Tombstone)` cannot answer on its
  own:

    * **Where.** Delivery targets are read from the follower table, i.e. whoever
      follows the member *now*. A server that received the post and has since
      unfollowed would never hear about the takedown, so the copy would stay up
      forever. The recorded inboxes are the set that actually got it.
    * **What.** A Note id is `/<username>/posts/<id>`, built from the username at
      send time. After a rename (issue #1086) an id built from the *current*
      username no longer matches what the remote server stored, so a delivered
      `Delete` would match nothing. The id is therefore recorded verbatim
      alongside the inbox.

  Deliberately **no foreign key** into `posts`: the revocation runs after the
  post row is gone (`Vutuv.Posts.delete_post/1` federates the `Delete` after the
  commit), so a cascade would erase these rows moments before they are needed.
  They are cleared explicitly instead — by the revocation that used them
  (`Vutuv.Fediverse.revoke_post/1`), by account deletion
  (`drop_post_deliveries/1`) and by an instance block (`purge_instance/1`).

  Nothing here is content: an inbox URL, a public Note URL, and who published it.
  """

  use VutuvWeb, :model

  schema "fediverse_post_deliveries" do
    field(:post_id, :binary_id)
    field(:user_id, :binary_id)
    field(:inbox_uri, :string)
    field(:object_uri, :string)

    timestamps(updated_at: false)
  end
end
