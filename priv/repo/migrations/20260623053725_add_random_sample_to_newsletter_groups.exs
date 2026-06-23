defmodule Vutuv.Repo.Migrations.AddRandomSampleToNewsletterGroups do
  use Ecto.Migration

  def change do
    # When a group is capped (max_size), pick the members at random instead of
    # the oldest by creation time. Plain additive boolean, backward compatible.
    alter table(:newsletter_groups) do
      add(:random_sample, :boolean, null: false, default: false)
    end
  end
end
