defmodule Vutuv.Repo.Migrations.WidenProfileDescriptionColumns do
  @moduledoc """
  Job and education descriptions are prose: LinkedIn alone allows 2,000
  characters for a position description, but these columns were varchar(255),
  so applying an import with a real description raised 22001
  (string_data_right_truncation) inside the import transaction and 500ed the
  confirm step. Widening to text is N-1 safe — the previous release keeps
  reading and writing its shorter values unchanged.
  """
  use Ecto.Migration

  def change do
    alter table(:work_experiences) do
      modify(:description, :text, from: :string)
    end

    alter table(:educations) do
      modify(:description, :text, from: :string)
    end
  end
end
