defmodule Vutuv.Repo.Migrations.AddGenderToUsers do
  @moduledoc """
  Adds `gender`, a voluntary answer kept for the membership statistic only.

  This is **not** the column of the same name that `20260804132928` dropped, and
  it is not a second `salutation`. The two answer different questions and are
  stored apart on purpose: `salutation` says how a member wants to be addressed
  in a letter and drives the German email greeting, while `gender` drives
  nothing a member ever sees. Merging them would make the statistic worthless,
  because an answer that changes how the site treats you stops being an answer
  and becomes a preference: anyone wanting "Liebe Frau Meier" would have to
  declare female to get it.

  The two addressable salutations seed it, because that is where the old
  classification went: `20260804082102` copied `gender` into `salutation` when
  the sign-up form stopped asking, so reading it back recovers the member's own
  earlier answer rather than inferring a gender from a courtesy title. Anyone
  who has edited their salutation since v7.229.0 is seeded from that newer
  choice, which is the better of the two.

  What this migration deliberately does **not** restore is the third answer.
  That one mapped to "no salutation" and is therefore indistinguishable here
  from the members who never answered at all, so those rows are seeded out of
  band from a database dump predating the drop, by id, in a file that is not in
  this repository and never will be: a public repo may not carry a list naming
  which members answered what. See `docs/architecture/settings-and-account.md`.
  After that step the breakdown shows at `/admin`, and

      SELECT gender, count(*) FROM users GROUP BY gender ORDER BY 2 DESC;

  is how you check it landed.

  One caveat the statistic has to carry: the sign-up form preselected "male"
  until v7.229.0, so a seeded `male` may be an answer or an untouched default,
  while `female` and the third value were only ever reached by overriding that
  default. Members correct their own row on /settings/profile.
  """
  use Ecto.Migration

  def up do
    alter table(:users) do
      add(:gender, :string)
    end

    flush()

    execute("UPDATE users SET gender = 'female' WHERE salutation = 'ms'")
    execute("UPDATE users SET gender = 'male' WHERE salutation = 'mr'")
  end

  def down do
    alter table(:users) do
      remove(:gender)
    end
  end
end
