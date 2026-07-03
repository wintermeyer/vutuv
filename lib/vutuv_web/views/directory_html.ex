defmodule VutuvWeb.DirectoryHTML do
  @moduledoc false
  use VutuvWeb, :html

  embed_templates("../templates/directory/*")

  @doc ~S(The human label of a letter segment: "A" for "a", a word for the non-letter bucket.)
  def display_letter("other"), do: gettext("Other")
  def display_letter(letter), do: String.upcase(letter)
end
