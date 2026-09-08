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

  @doc """
  The opening sentence of the mail that tells a member their content was
  reported — one whole sentence per content type, in the recipient's locale.

  It is a sentence and not a noun in a frame, because German gives each kind
  its own gender and its own article (der Beitrag, das Bild, die Nachricht, die
  Seite, die Stellenanzeige) and a profile is not "one of your" anything. Both
  owner mails opened with the post wording for every type until issue #2067, so
  a member whose profile picture had been taken offline was told a post of
  theirs was hidden and went looking through posts that were all still there.

  It reads lower-case and ends in a full stop: it follows the greeting's comma,
  which is how a German letter continues and how these templates are written.
  Everything after it in the body says "the reported content", so this is the
  only sentence the type reaches.
  """
  def content_reported_sentence("post"),
    do: gettext("somebody reported one of your posts on vutuv.")

  def content_reported_sentence("image"),
    do: gettext("somebody reported one of your pictures on vutuv.")

  def content_reported_sentence("message"),
    do: gettext("somebody reported one of your private messages on vutuv.")

  def content_reported_sentence("job_posting"),
    do: gettext("somebody reported one of your job postings on vutuv.")

  def content_reported_sentence("organization"),
    do: gettext("somebody reported one of your pages on vutuv.")

  def content_reported_sentence("user"),
    do: gettext("somebody reported your profile on vutuv.")

  def content_reported_sentence(_other),
    do: gettext("somebody reported something of yours on vutuv.")

  @doc """
  Why the content is already hidden, for the owner mails: whoever reported it
  had a clean record, and that is the whole decision.

  Both mails said "a report from a **member** in good standing", which for an
  outside notice (issue #2009) names somebody who has no account here and points
  the owner at the wrong people (issue #2067). One sentence per shape, handed to
  the six templates as an assign, because the difference is one noun and
  branching it in each locale of each mail is twelve copies to keep in step.
  """
  def reporter_standing_sentence(true),
    do:
      gettext(
        "A report from a member in good standing hides the reported content automatically, the moment it arrives."
      )

  def reporter_standing_sentence(_outside),
    do:
      gettext(
        "A report from somebody with a good record hides the reported content automatically, the moment it arrives."
      )

  @doc "Whether this content type's form carries the copyright notice at all."
  def copyright_offered?(content_type),
    do: Report.copyright_category() in Report.categories_for(content_type)
end
