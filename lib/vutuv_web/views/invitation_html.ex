defmodule VutuvWeb.InvitationHTML do
  @moduledoc false
  use VutuvWeb, :html

  alias Vutuv.Accounts.User

  embed_templates("../templates/invitation/*")

  @doc "The language choices for an invitation, as {label, value} pairs."
  def locale_options do
    [{gettext("English"), "en"}, {gettext("Deutsch"), "de"}]
  end

  @doc """
  The salutation choices for the prefilled sign-up, with a leave-blank first
  option.

  Deliberately not `VutuvWeb.UserHelpers.salutation_options/0`: there the blank
  choice is the member's own "No salutation" and comes last as an equal answer,
  while here it is the inviter's "I would rather not say for someone else" and
  belongs first, as the default an inviter passes over. The two labels come from
  the schema either way, so the wording cannot drift.
  """
  def salutation_options do
    [
      {gettext("Prefer not to say"), ""}
      | Enum.map(User.salutations(), &{User.salutation_label(&1), &1})
    ]
  end
end
