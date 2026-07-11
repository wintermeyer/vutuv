defmodule VutuvWeb.ReportHTML do
  @moduledoc false
  use VutuvWeb, :html

  embed_templates("../templates/report/*")

  @doc """
  The human name of a report category, in the viewer's locale — the single
  home of this mapping; the case page and the admin views call it too.
  """
  def category_label("family"), do: gettext("Not family-friendly")
  def category_label("bullying"), do: gettext("Bullying or harassment")
  def category_label("spam"), do: gettext("Spam or scam")
  def category_label("misleading_job"), do: gettext("Misleading job posting")
  def category_label(_), do: gettext("Something else")

  @doc "The helper line under each category on the report form."
  def category_hint("family"),
    do: gettext("Nudity, violence or other content that does not belong on vutuv.")

  def category_hint("bullying"), do: gettext("Targets, demeans or threatens a person.")
  def category_hint("spam"), do: gettext("Unwanted advertising, fraud or fake activity.")

  def category_hint("misleading_job"),
    do: gettext("A fake, misleading or discriminatory job advertisement.")

  def category_hint(_), do: gettext("Tell us more in the note below.")
end
