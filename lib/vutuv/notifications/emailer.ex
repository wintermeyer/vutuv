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
  use Gettext, backend: VutuvWeb.Gettext
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

  def login_email(pin, email, %Vutuv.Accounts.User{activated?: false} = user) do
    gen_email(pin, email, user, "registration_email", fn ->
      gettext("Confirm your vutuv account")
    end)
  end

  def login_email(pin, email, user) do
    gen_email(pin, email, user, "login_email", fn ->
      gettext("Login to vutuv")
    end)
  end

  def email_creation_email(pin, email, user) do
    gen_email(pin, email, user, "email_creation_email", fn ->
      gettext("Confirm your email")
    end)
  end

  def user_deletion_email(pin, email, user) do
    gen_email(pin, email, user, "user_deletion_email", fn ->
      gettext("Confirm your account deletion")
    end)
  end

  def verification_notice(user) do
    email = Vutuv.Accounts.first_email_value(user)
    locale = get_locale(user.locale)

    base_email()
    |> to({VutuvWeb.UserHelpers.name_for_email_to_field(user), email})
    |> subject(
      recipient_subject(locale, fn ->
        gettext("vutuv Account verified")
      end)
    )
    |> text_body(
      VutuvWeb.EmailText.render("verification_confirmation_#{locale}.text", %{
        user: user,
        url: public_url()
      })
    )
  end

  @doc """
  The debounced "you have an unread message" notice (see
  `Vutuv.Chat.send_unread_notifications/0`). Names the sender by @handle only
  — system text never uses clear names. The caller passes the recipient's
  address (it already looked it up to decide whether to send at all).
  """
  def unread_messages_email(email, user, other, conversation_id) do
    locale = get_locale(user.locale)

    base_email()
    |> to({VutuvWeb.UserHelpers.name_for_email_to_field(user), email})
    |> subject(
      recipient_subject(locale, fn ->
        gettext("New message from @%{slug} on vutuv",
          slug: other.active_slug
        )
      end)
    )
    |> text_body(
      VutuvWeb.EmailText.render("unread_messages_#{locale}.text", %{
        user: user,
        other_slug: other.active_slug,
        conversation_id: conversation_id,
        url: public_url()
      })
    )
  end

  ## Moderation (see Vutuv.Moderation.Notifier, the only caller)

  @doc "Owner notice: content frozen, please delete / edit / dispute within 72h."
  def moderation_frozen_email(user, email, case_record) do
    build_email(user, email, "moderation_frozen", %{case_id: case_record.id}, fn ->
      gettext("Your content on vutuv was reported and is hidden")
    end)
  end

  @doc "Owner notice: content frozen and with the admins (no self-service round)."
  def moderation_review_email(user, email, case_record) do
    build_email(user, email, "moderation_review", %{case_id: case_record.id}, fn ->
      gettext("Your content on vutuv is under review")
    end)
  end

  @doc "Reporter notice: the content they reported was revised by its owner."
  def moderation_revised_email(user, email) do
    build_email(user, email, "moderation_revised", %{}, fn ->
      gettext("The content you reported was revised")
    end)
  end

  @doc "Strike 1: the formal warning."
  def moderation_warning_email(user, email) do
    build_email(user, email, "moderation_warning", %{}, fn ->
      gettext("A warning for your vutuv account")
    end)
  end

  @doc "Strike 2: the one-week suspension."
  def moderation_suspension_email(user, email, until) do
    build_email(user, email, "moderation_suspension", %{until: until}, fn ->
      gettext("Your vutuv account is suspended")
    end)
  end

  @doc "Strike 3: deactivated for good."
  def moderation_deactivation_email(user, email) do
    build_email(user, email, "moderation_deactivation", %{}, fn ->
      gettext("Your vutuv account has been deactivated")
    end)
  end

  @doc "Admin alert: a whole profile was reported (urgent, sent immediately)."
  def moderation_admin_urgent_email(user, email, case_record) do
    build_email(user, email, "moderation_admin_urgent", %{case_id: case_record.id}, fn ->
      gettext("Moderation: a profile was reported")
    end)
  end

  @doc "Admin daily digest: how many cases wait in the queue."
  def moderation_admin_digest_email(user, email, open_count) do
    build_email(user, email, "moderation_admin_digest", %{open_count: open_count}, fn ->
      gettext("Moderation: %{count} cases are waiting",
        count: open_count
      )
    end)
  end

  defp gen_email(pin, email, user, template_base, subject_fun) do
    build_email(user, email, template_base, %{pin: pin}, subject_fun)
  end

  # Every templated email: recipient, localized subject, and the matching
  # per-locale text template with `user` + `url` always in its assigns.
  defp build_email(user, email, template_base, extra_assigns, subject_fun) do
    locale = get_locale(user.locale)

    base_email()
    |> to({VutuvWeb.UserHelpers.name_for_email_to_field(user), email})
    |> subject(recipient_subject(locale, subject_fun))
    |> text_body(
      VutuvWeb.EmailText.render(
        "#{template_base}_#{locale}.text",
        Map.merge(%{user: user, url: public_url()}, extra_assigns)
      )
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
