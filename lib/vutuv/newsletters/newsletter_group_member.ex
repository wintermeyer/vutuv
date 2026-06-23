defmodule Vutuv.Newsletters.NewsletterGroupMember do
  @moduledoc """
  One member of a `NewsletterGroup`: the frozen membership snapshot. Rows are
  written in bulk by `Vutuv.Newsletters` when a group is saved, never cast.
  """

  use VutuvWeb, :model

  alias Vutuv.Newsletters.NewsletterGroup

  schema "newsletter_group_members" do
    belongs_to(:group, NewsletterGroup)
    belongs_to(:user, Vutuv.Accounts.User)

    timestamps()
  end
end
