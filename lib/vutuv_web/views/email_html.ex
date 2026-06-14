defmodule VutuvWeb.EmailHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  @doc """
  The stored type values are the English option values from the form
  ("Work", "Personal", "Other"); render them through gettext so the page
  speaks the visitor's language. Unknown legacy values pass through unchanged.
  """
  def email_type_label("Work"), do: gettext("Work")
  def email_type_label("Personal"), do: gettext("Personal")
  def email_type_label("Other"), do: gettext("Other")
  def email_type_label(other), do: other

  embed_templates("../templates/email/*.html")
end
