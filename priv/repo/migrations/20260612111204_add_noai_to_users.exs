defmodule Vutuv.Repo.Migrations.AddNoaiToUsers do
  use Ecto.Migration

  # The per-member AI consent (the counterpart to noindex?): may AI agents
  # and LLMs use this member's content (training and live retrieval)?
  #
  # The column default is TRUE (= opted out) on purpose, twice over:
  #   * it backfills every existing member as "no AI" — they were never
  #     asked, so we play it safe;
  #   * during the blue/green window the previous release registers users
  #     without asking the question, and the DB default keeps those safe
  #     too (N-1 compatibility).
  # New code asks at registration and always writes an explicit value; the
  # schema default in Vutuv.Accounts.User is false (allow), matching the
  # pre-checked consent box, so only unasked paths fall back to "no".
  def change do
    alter table(:users) do
      add(:noai?, :boolean, default: true, null: false)
    end
  end
end
