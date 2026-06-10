defmodule Vutuv.Repo.Migrations.AddEvidenceScreenshotToModerationCases do
  use Ecto.Migration

  def change do
    alter table(:moderation_cases) do
      # Filename of the full-page evidence screenshot captured at report time
      # (profile and message cases), stored under the private
      # moderation_evidence/ tree. nil = none (captured asynchronously, posts
      # keep their text snapshot).
      add(:evidence_screenshot, :string)
    end
  end
end
