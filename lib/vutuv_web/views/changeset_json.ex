defmodule VutuvWeb.ChangesetJSON do
  @moduledoc false
  import VutuvWeb.ErrorHelpers

  def render("error.json", %{changeset: changeset}) do
    %{errors: translate_errors(changeset)}
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, &translate_error/1)
  end
end
