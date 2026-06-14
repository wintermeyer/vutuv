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

  require Logger

  alias Vutuv.Notifications.Bounces
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
    |> envelope_sender()
  end

  @doc """
  The single delivery chokepoint for all outbound mail. Re-applies the robot
  headers and the bounce envelope sender, drops automatic mail to addresses
  a bounce marked undeliverable (`Vutuv.Notifications.Bounces`), and hands
  everything else to `Vutuv.Mailer`. User-initiated mail (the PIN flows, ad
  bookings — `put_private(:user_initiated, true)`) is exempt from the
  suppression: a member whose mailbox once bounced must still be able to
  request a login PIN, and a verified PIN clears the mark again.
  """
  def deliver(%Swoosh.Email{} = email) do
    if suppressed?(email) do
      Logger.info("Suppressed email \"#{email.subject}\" to undeliverable address")
      :suppressed
    else
      email
      |> robot_headers()
      |> envelope_sender()
      |> Vutuv.Mailer.deliver()
    end
  end

  defp suppressed?(%Swoosh.Email{private: %{user_initiated: true}}), do: false

  defp suppressed?(%Swoosh.Email{to: to}) when is_list(to) and to != [] do
    Enum.all?(to, fn {_name, address} -> Bounces.suppressed?(address) end)
  end

  defp suppressed?(_email), do: false

  # The Swoosh SMTP adapter uses the Sender header as the SMTP envelope
  # sender (MAIL FROM), so every DSN comes back to the one bounce mailbox
  # production Postfix pipes into POST /webhooks/bounces. The visible From
  # stays info@vutuv.de.
  defp envelope_sender(email), do: header(email, "Sender", bounce_address())

  defp bounce_address, do: Application.fetch_env!(:vutuv, :bounce_address)

  @doc """
  Adds the bulk-only headers (`Precedence: bulk`, `List-Unsubscribe`). These are
  **not** safe for one-to-one transactional mail because `Precedence: bulk` can
  hurt inbox placement, so they are opt-in and applied only to bulk mail.
  """
  def bulk_headers(%Swoosh.Email{} = email), do: put_headers(email, @bulk_headers)

  def login_email(pin, email, %Vutuv.Accounts.User{email_confirmed?: false} = user) do
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

  @doc """
  Sent to the owner of an existing account when someone tries to register
  again with their address. The sign-up form deliberately returns the
  identical screen for known and unknown addresses, so it never reveals
  whether an account exists (`Vutuv.Accounts.notify_registration_attempt/2`);
  the only place the truth surfaces is the owner's own inbox. The notice
  carries no PIN, just a link to the login page, so it hands nothing
  actionable to anyone who is not the mailbox owner. Built with `build_email`
  (not `gen_email`), so it is not user-initiated and stays subject to the
  bounce suppression in `deliver/1` — a third party cannot keep mailing a
  dead address.
  """
  def registration_attempt_email(user, email) do
    build_email(user, email, "registration_attempt", %{}, fn ->
      gettext("Someone tried to register with your email address")
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
    unsubscribe_url = VutuvWeb.UnsubscribeToken.url(user)

    base_email()
    |> to({VutuvWeb.UserHelpers.name_for_email_to_field(user), email})
    |> unsubscribe_headers(unsubscribe_url)
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
        url: public_url(),
        unsubscribe_url: unsubscribe_url
      })
    )
  end

  # RFC 8058 one-click unsubscribe for notification (non-transactional) mail:
  # the HTTPS form is what Gmail/Yahoo's unsubscribe buttons POST to, the
  # mailto is the fallback for everything else. Transactional mail (PINs,
  # moderation notices) must NOT carry these - it cannot be opted out of.
  defp unsubscribe_headers(email, url) do
    email
    |> header("List-Unsubscribe", "<#{url}>, <mailto:info@vutuv.de?subject=unsubscribe>")
    |> header("List-Unsubscribe-Post", "List-Unsubscribe=One-Click")
  end

  ## Ad bookings (see Vutuv.Ads.book_ad/2, the only caller)

  @ad_booking_recipient {"Stefan Wintermeyer", "sw@wintermeyer-consulting.de"}

  @doc """
  The operator notice for a new ad booking: the booked day, the billing
  address and the full ad text — everything the manually written invoice
  needs. The recipient is the (German) operator, not the booker, so subject
  and template are fixed German rather than locale-selected.
  """
  def ad_booking_email(%Vutuv.Ads.Ad{} = ad, booker) do
    base_email()
    # A booking the member just made; never suppressed (see deliver/1).
    |> put_private(:user_initiated, true)
    |> to(@ad_booking_recipient)
    |> subject("vutuv Anzeigenbuchung für den #{Calendar.strftime(ad.day, "%d.%m.%Y")}")
    |> text_body(
      VutuvWeb.EmailText.render("ad_booking_de.text", %{
        ad: ad,
        booker: booker,
        booker_email: Vutuv.Accounts.first_email_value(booker),
        billing_address: billing_address(ad),
        price: format_euro_cents(ad.price_cents),
        url: public_url()
      })
    )
  end

  # The invoice address block, optional lines (company, VAT id) folded away.
  defp billing_address(ad) do
    [
      ad.billing_name,
      ad.billing_company,
      ad.billing_street,
      "#{ad.billing_zip_code} #{ad.billing_city}",
      ad.billing_country,
      ad.vat_id && "USt-IdNr.: #{ad.vat_id}"
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  # 125000 -> "1.250,00" (fixed German formatting, like the recipient).
  defp format_euro_cents(cents) do
    euros =
      div(cents, 100)
      |> Integer.to_string()
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1.")
      |> String.reverse()

    decimals = rem(cents, 100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{euros},#{decimals}"
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
  # `case_record` arrives with owner + reports/reporters preloaded (see
  # `Vutuv.Moderation.Notifier.admins_urgent/1`): the mail carries the
  # substance of the case - who, reported as what, the reporter's note - so
  # the admin knows what they are walking into before clicking.
  def moderation_admin_urgent_email(user, email, case_record) do
    report =
      case_record.reports
      |> Enum.sort_by(& &1.inserted_at, NaiveDateTime)
      |> List.last()

    assigns = %{
      case_id: case_record.id,
      owner_slug: case_record.owner.active_slug,
      category_label: localized_category_label(report, user),
      note: report && presence(report.note),
      report_count: length(case_record.reports)
    }

    build_email(user, email, "moderation_admin_urgent", assigns, fn ->
      gettext("Moderation: a profile was reported")
    end)
  end

  # The category in the *recipient's* language (the body template is selected
  # by their locale, so the label must match it).
  defp localized_category_label(nil, _user), do: nil

  defp localized_category_label(report, user) do
    Gettext.with_locale(VutuvWeb.Gettext, get_locale(user.locale), fn ->
      VutuvWeb.ReportHTML.category_label(report.category)
    end)
  end

  defp presence(nil), do: nil

  defp presence(string) when is_binary(string),
    do: if(String.trim(string) == "", do: nil, else: string)

  @doc "Admin daily digest: how many cases wait in the queue."
  def moderation_admin_digest_email(user, email, open_count) do
    build_email(user, email, "moderation_admin_digest", %{open_count: open_count}, fn ->
      gettext("Moderation: %{count} cases are waiting",
        count: open_count
      )
    end)
  end

  # PIN mail is user-initiated: someone just asked for it, so it is exempt
  # from the bounce suppression in deliver/1 (the way back into a once-
  # bounced account must stay open).
  defp gen_email(pin, email, user, template_base, subject_fun) do
    build_email(user, email, template_base, %{pin: pin}, subject_fun)
    |> put_private(:user_initiated, true)
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
