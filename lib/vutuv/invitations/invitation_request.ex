defmodule Vutuv.Invitations.InvitationRequest do
  @moduledoc """
  The invite form's own schema (not persisted). It carries everything the
  inviter fills in: the sign-up fields to prefill on the invited person's
  registration form (gender, name, tags, email), the optional personalized
  message that goes into the email body, whether to auto-follow once they
  register, and the language of the invitation.

  Only `email` plus at least one of `first_name` / `last_name` are required —
  the invited person completes the rest (the sign-up form's tag minimum,
  consent choices, ...) themselves. The persisted `Vutuv.Invitations.Invitation`
  keeps only a hash of the email, so nothing here but the language and the
  auto-follow flag survives past the email send.
  """
  use Ecto.Schema

  import Ecto.Changeset

  # Match the sign-up form's own caps so a prefilled value can't be one the
  # registration changeset would then reject.
  @max_name 50
  @max_email 254
  @max_message 2_000
  @genders ~w(male female other)
  @locales ~w(en de)

  @primary_key false
  embedded_schema do
    field(:gender, :string)
    field(:first_name, :string)
    field(:last_name, :string)
    field(:tag_list, :string)
    field(:email, :string)
    field(:message, :string)
    field(:auto_follow, :boolean, default: false)
    field(:locale, :string, default: "en")
  end

  def changeset(request, attrs) do
    request
    |> cast(attrs, [
      :gender,
      :first_name,
      :last_name,
      :tag_list,
      :email,
      :message,
      :auto_follow,
      :locale
    ])
    |> update_change(:email, &trim/1)
    |> update_change(:first_name, &trim/1)
    |> update_change(:last_name, &trim/1)
    |> validate_required([:email, :locale])
    |> validate_first_or_last_name()
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email address"
    )
    |> validate_length(:email, max: @max_email)
    |> validate_length(:first_name, max: @max_name)
    |> validate_length(:last_name, max: @max_name)
    |> validate_length(:message, max: @max_message)
    |> validate_inclusion(:gender, @genders)
    |> validate_inclusion(:locale, @locales)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(value)

  # The invited person needs a name to prefill, so require at least one part —
  # the same "first or last (or nickname)" spirit the User registration
  # changeset enforces, minus nickname (the invite form doesn't collect it).
  defp validate_first_or_last_name(changeset) do
    first = get_field(changeset, :first_name)
    last = get_field(changeset, :last_name)

    if present?(first) or present?(last) do
      changeset
    else
      add_error(changeset, :first_name, "or a last name is required")
    end
  end

  defp present?(nil), do: false
  defp present?(value), do: String.trim(value) != ""
end
