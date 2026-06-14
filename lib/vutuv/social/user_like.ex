defmodule Vutuv.Social.UserLike do
  @moduledoc false

  use VutuvWeb, :model

  schema "user_likes" do
    # The actor who saved, and the saved member. A private, silent save: it
    # creates no follow/connection and notifies no one (see Vutuv.Social).
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:target_user, Vutuv.Accounts.User)

    timestamps()
  end
end
