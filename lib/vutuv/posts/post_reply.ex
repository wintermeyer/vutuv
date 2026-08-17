defmodule Vutuv.Posts.PostReply do
  @moduledoc false

  use VutuvWeb, :model

  schema "post_replies" do
    # The reply post itself; the row cascades away with it.
    belongs_to(:post, Vutuv.Posts.Post)
    # The post replied to and its author at reply time. All three nilify on
    # deletion, so the reply outlives its parent (see the migration for the
    # banner-state encoding).
    belongs_to(:parent_post, Vutuv.Posts.Post)
    # The two kinds of author a parent can have (issue #1334): a member, or the
    # page the parent was published in the name of. Exactly one of them is set
    # while the parent lives; both are NULL once the account or page behind it
    # is gone, which is what the nameless banner state reads.
    belongs_to(:parent_author, Vutuv.Accounts.User)
    belongs_to(:parent_organization, Vutuv.Organizations.Organization)
    # The thread's top post, denormalized at creation (threading is otherwise
    # only a parent-pointer chain) so "all replies in this thread" is one
    # indexed lookup — the seam behind the thread-participation notifications.
    # Nilifies with the root; NULL keeps the reply out of thread events.
    belongs_to(:root_post, Vutuv.Posts.Post)

    timestamps()
  end
end
