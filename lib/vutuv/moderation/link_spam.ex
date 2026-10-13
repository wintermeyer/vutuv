defmodule Vutuv.Moderation.LinkSpam do
  @moduledoc """
  Freezes a brand-new account that was registered to plant a link.

  The accounts of October 2026 gave one random lowercase word as their only
  name, confirmed their address and then wrote an address and a line of
  search-engine copy into the headline. The registration form never sees a
  headline, so `Vutuv.SignupTrap` cannot catch that; this check looks at the
  account afterwards. Its rule: registered within the last day, exactly one of
  first and last name, and a headline with a link that leaves the site
  (`VutuvWeb.Markdown.foreign_link?/1`, so a pasted address counts like a
  Markdown link).

  A match is frozen (`Vutuv.Moderation.auto_freeze_user/2`), never deleted:
  the profile disappears for everybody but its owner and the admins, and the
  operator reads about it in the next daily report and on
  `/admin/accounts/frozen`, where thawing or deleting it is one click. An
  account that already has an entry in the admin ledger is left alone, so
  thawing one is final.

  `Vutuv.Moderation.LinkSpamSweeper` runs this every 30 minutes. Nothing is
  remembered between runs: what is due is the query, so a deploy or a crash
  costs half an hour and no account.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Moderation
  alias Vutuv.Moderation.AdminAction
  alias Vutuv.Repo
  alias VutuvWeb.Markdown

  @rule "new_account_link"
  # A day, plus one interval of the sweeper: a headline written in the last
  # minutes of the day is still inside the window at the check after it.
  @window_minutes 24 * 60 + 30

  @doc "The rule name an automatic freeze records in the admin ledger."
  def rule, do: @rule

  @doc "One pass at `now`. Returns how many accounts it froze."
  def run(now \\ NaiveDateTime.utc_now(:second)) do
    now
    |> candidates()
    |> Enum.filter(&Markdown.foreign_link?(&1.headline))
    |> Enum.count(&(Moderation.auto_freeze_user(&1, @rule) == {:ok, :frozen}))
  end

  # Everything the rule can ask of the database. Whether the headline holds a
  # link is asked of the renderer afterwards, on the handful of rows left.
  defp candidates(now) do
    since = NaiveDateTime.add(now, -@window_minutes, :minute)

    Repo.all(
      from(u in User,
        where: u.inserted_at > ^since,
        where: u.email_confirmed? == true and u.admin? != true,
        where: is_nil(u.frozen_at) and is_nil(u.deactivated_at),
        where: not is_nil(u.headline) and u.headline != "",
        where:
          fragment(
            "(coalesce(?, '') = '') <> (coalesce(?, '') = '')",
            u.first_name,
            u.last_name
          ),
        where: u.id not in subquery(judged_ids()),
        order_by: [asc: u.id]
      )
    )
  end

  # Named, because it feeds a NOT IN: `user_id` is nullable in the ledger, and
  # one NULL in the list would make the predicate false for every account.
  defp judged_ids do
    from(a in AdminAction, where: not is_nil(a.user_id), select: a.user_id)
  end
end
