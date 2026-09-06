defmodule VutuvWeb.ReportHTML do
  @moduledoc false
  use VutuvWeb, :html

  alias Vutuv.Moderation.Report

  embed_templates("../templates/report/*")

  @doc """
  The human name of a report category, in the viewer's locale — the single
  home of this mapping; the case page and the admin views call it too.
  """
  def category_label("family"), do: gettext("Not family-friendly")
  def category_label("bullying"), do: gettext("Bullying or harassment")
  def category_label("spam"), do: gettext("Spam or scam")
  def category_label("misleading_job"), do: gettext("Misleading job posting")

  def category_label("copyright"),
    do: gettext("Uses a text, photo or video without the rights holder's permission")

  def category_label(_), do: gettext("Something else")

  @doc "The helper line under each category on the report form."
  def category_hint("family"),
    do: gettext("Nudity, violence or other content that does not belong on vutuv.")

  def category_hint("bullying"), do: gettext("Targets, demeans or threatens a person.")
  def category_hint("spam"), do: gettext("Unwanted advertising, fraud or fake activity.")

  def category_hint("misleading_job"),
    do: gettext("A fake, misleading or discriminatory job advertisement.")

  def category_hint("copyright"),
    do: gettext("Tell us which work it is and where the original can be seen.")

  def category_hint(_), do: gettext("Tell us more in the note below.")

  @doc """
  The human name of a reportable content type, in the viewer's locale — the
  single home of this mapping, beside `category_label/1`, for the same reason:
  the admin queue, the admin case page, the urgent admin mail and the receipt a
  rights holder gets (issue #2009) must not name the same thing differently.

  Each carries a `pgettext` context. Without one, "Post" shares a msgid with the
  composer's verb and with the screenshot admin's, and the German for those is
  "Posten" — which is what the receipt mail said a rights holder had reported.
  """
  def content_type_label("post"), do: pgettext("content type", "Post")
  def content_type_label("message"), do: pgettext("content type", "Private message")
  def content_type_label("user"), do: pgettext("content type", "Profile")
  def content_type_label("organization"), do: pgettext("content type", "Organization page")
  def content_type_label("job_posting"), do: pgettext("content type", "Job posting")
  def content_type_label("image"), do: pgettext("content type", "Picture")
  def content_type_label(other), do: other

  @doc "Whether this content type's form carries the copyright notice at all."
  def copyright_offered?(content_type),
    do: Report.copyright_category() in Report.categories_for(content_type)
end
