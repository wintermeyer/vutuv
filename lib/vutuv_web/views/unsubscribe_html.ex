defmodule VutuvWeb.UnsubscribeHTML do
  @moduledoc false
  use VutuvWeb, :html

  embed_templates("../templates/unsubscribe/*")

  @doc """
  A human label for the preference a token switches off, so the confirmation
  page names the right kind of mail (newsletter vs the per-event notices). The
  phrase is written to slot into the page's sentences in both languages.
  """
  def pref_label(:newsletter_emails?), do: gettext("the vutuv newsletter")
  def pref_label(:notification_emails?), do: gettext("unread-message emails")
  def pref_label(:email_on_endorsement?), do: gettext("endorsement emails")
  def pref_label(:email_on_follower?), do: gettext("new-follower emails")
  def pref_label(:saved_search_emails?), do: gettext("saved-search alert emails")
  def pref_label(_field), do: gettext("these emails")
end
