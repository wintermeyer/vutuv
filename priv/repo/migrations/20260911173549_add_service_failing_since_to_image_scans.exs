defmodule Vutuv.Repo.Migrations.AddServiceFailingSinceToImageScans do
  use Ecto.Migration

  # When the scanner itself is unreachable the queue retries forever by design
  # — the image is fine, nothing may be auto-approved, and the outage ends when
  # the operator's Ollama comes back. What was written nowhere is *since when*,
  # so a post waiting on that verdict could not tell a two-minute blip from a
  # host whose scanner has been down for a month, and told its author "our AI
  # is checking 1 picture" either way (issue #2149).
  #
  # Nullable and additive: the release still serving traffic through the
  # blue/green switch never reads or writes it.
  def change do
    alter table(:image_scans) do
      add(:service_failing_since, :utc_datetime)
    end
  end
end
