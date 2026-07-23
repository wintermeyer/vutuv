defmodule Vutuv.Repo.Migrations.AddVerdictRecordToImageScans do
  use Ecto.Migration

  # The vision model now answers with one sentence describing what it saw
  # before it judges it, and an unsafe answer is put to a vote. Keeping both
  # is what makes a verdict explainable afterwards: a deleted image leaves no
  # other trace, the bare category ("shocking") never said what the model
  # actually looked at, and logs rotate while this row does not.
  #
  # `reason` is text, not varchar: machine-written prose, capped in code.
  # `votes` holds the ballot (`%{"total", "unsafe", "opinions" => [...]}`),
  # so a rejection can be re-read as "three voices on one thing" vs "three
  # different suspicions", and a *cleared* suspicion stays findable — those
  # near misses are the material for tuning the prompt.
  def change do
    alter table(:image_scans) do
      add(:reason, :text)
      add(:votes, :map)
    end
  end
end
