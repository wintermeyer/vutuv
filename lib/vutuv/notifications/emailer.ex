defmodule Vutuv.Notifications.Emailer do
  @moduledoc """
  Builds and delivers every outbound vutuv email.

  All mail vutuv sends is machine-generated (login PINs, registration, email
  confirmation, account deletion, verification notices), so two things are
  guaranteed here in exactly one place:

    * `base_email/0` sets the `From` and the auto-generated robot headers that
      tell a recipient's mail system not to auto-reply (no out-of-office /
      vacation responder bouncing back to `info@vutuv.de`).
    * `deliver/1` is the single delivery chokepoint. It re-applies the robot
      headers (belt and suspenders, in case a future builder forgets the base)
      and hands the message to `Vutuv.Mailer`.

  No code outside this module may call `Vutuv.Mailer.deliver/1` or Swoosh
  directly. Every builder function returns a `%Swoosh.Email{}`; `deliver/1`
  sends it.
  """

  import Swoosh.Email
  alias VutuvWeb.Plug.Locale

  @from_address {"vutuv", "info@vutuv.de"}

  # Always-safe headers for every message.
  #
  #   * Auto-Submitted: auto-generated — RFC 3834. A conforming responder
  #     (including vacation/OOO) must not reply to a message carrying it.
  #   * X-Auto-Response-Suppress: All — Microsoft Exchange / Outlook. Suppresses
  #     out-of-office, auto-replies, and delivery/read receipts.
  @robot_headers [
    {"Auto-Submitted", "auto-generated"},
    {"X-Auto-Response-Suppress", "All"}
  ]

  # Opt-in headers for bulk mail only (see bulk_headers/1).
  @bulk_headers [
    {"Precedence", "bulk"},
    {"List-Unsubscribe", "<mailto:info@vutuv.de?subject=unsubscribe>"}
  ]

  @doc """
  Base builder every email starts from. Sets the `From` and the auto-generated
  robot headers, so those live in exactly one place.
  """
  def base_email do
    new()
    |> from(@from_address)
    |> robot_headers()
  end

  @doc """
  The single delivery chokepoint for all outbound mail. Re-applies the robot
  headers and then hands the message to `Vutuv.Mailer`.
  """
  def deliver(%Swoosh.Email{} = email) do
    email
    |> robot_headers()
    |> Vutuv.Mailer.deliver()
  end

  @doc """
  Adds the bulk-only headers (`Precedence: bulk`, `List-Unsubscribe`). These are
  **not** safe for one-to-one transactional mail because `Precedence: bulk` can
  hurt inbox placement, so they are opt-in and applied only to bulk mail.
  """
  def bulk_headers(%Swoosh.Email{} = email), do: put_headers(email, @bulk_headers)

  def login_email(pin, email, %Vutuv.Accounts.User{validated?: false} = user) do
    gen_email(pin, email, user, "registration_email", fn ->
      Gettext.gettext(VutuvWeb.Gettext, "Confirm your vutuv account")
    end)
  end

  def login_email(pin, email, user) do
    gen_email(pin, email, user, "login_email", fn ->
      Gettext.gettext(VutuvWeb.Gettext, "Login to vutuv")
    end)
  end

  def email_creation_email(pin, email, user) do
    gen_email(pin, email, user, "email_creation_email", fn ->
      Gettext.gettext(VutuvWeb.Gettext, "Confirm your email")
    end)
  end

  def user_deletion_email(pin, email, user) do
    gen_email(pin, email, user, "user_deletion_email", fn ->
      Gettext.gettext(VutuvWeb.Gettext, "Confirm your account deletion")
    end)
  end

  def verification_notice(user) do
    email = Vutuv.Accounts.first_email_value(user)
    locale = get_locale(user.locale)

    base_email()
    |> to({VutuvWeb.UserHelpers.name_for_email_to_field(user), email})
    |> subject(
      recipient_subject(locale, fn ->
        Gettext.gettext(VutuvWeb.Gettext, "vutuv Account verified")
      end)
    )
    |> text_body(
      VutuvWeb.EmailText.render("verification_confirmation_#{locale}.text", %{
        user: user,
        url: public_url()
      })
    )
  end

  defp gen_email(pin, email, user, template_base, subject_fun) do
    locale = get_locale(user.locale)

    base_email()
    |> to({VutuvWeb.UserHelpers.name_for_email_to_field(user), email})
    |> subject(recipient_subject(locale, subject_fun))
    |> text_body(
      VutuvWeb.EmailText.render("#{template_base}_#{locale}.text", %{
        pin: pin,
        url: public_url(),
        user: user
      })
    )
  end

  # The configured canonical host (with a trailing slash), e.g.
  # "https://www.vutuv.de/" — every URL an email names builds on it.
  defp public_url, do: Application.get_env(:vutuv, VutuvWeb.Endpoint)[:public_url]

  # The body template is selected by the recipient's locale; render the
  # subject in that same locale, not the ambient process locale (which is the
  # *sender's* — e.g. the admin verifying another member).
  defp recipient_subject(locale, subject_fun) do
    Gettext.with_locale(VutuvWeb.Gettext, locale, subject_fun)
  end

  defp robot_headers(email), do: put_headers(email, @robot_headers)

  defp put_headers(email, headers) do
    Enum.reduce(headers, email, fn {name, value}, acc -> header(acc, name, value) end)
  end

  defp get_locale(nil), do: "en"

  defp get_locale(locale) do
    if Locale.locale_supported?(locale) do
      locale
    else
      "en"
    end
  end
end
