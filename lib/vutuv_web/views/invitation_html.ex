defmodule VutuvWeb.InvitationHTML do
  @moduledoc false
  use VutuvWeb, :html

  embed_templates("../templates/invitation/*")

  @doc "The language choices for an invitation, as {label, value} pairs."
  def locale_options do
    [{gettext("English"), "en"}, {gettext("Deutsch"), "de"}]
  end

  @doc "The gender choices for the prefilled sign-up, with a leave-blank first option."
  def gender_options do
    [
      {gettext("Prefer not to say"), ""},
      {gettext("Male"), "male"},
      {gettext("Female"), "female"},
      {gettext("Other"), "other"}
    ]
  end
end
