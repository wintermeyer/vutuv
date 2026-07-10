defmodule Vutuv.Notifications.Emailer do
  @moduledoc """
  Builds and delivers every outbound vutuv email.

  All mail vutuv sends is machine-generated (login PINs, registration, email
  confirmation, account deletion, verification notices), so two things are
  guaranteed here in exactly one place:

    * `base_email/0` sets the `From` and the auto-generated robot headers that
      tell a recipient's mail system not to auto-reply (no out-of-office /
      vacation responder bouncing back to `no-reply@vutuv.de`).
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

  alias Vutuv.Invitations.PrefillToken
  alias Vutuv.Notifications.Bounces
  alias Vutuv.Reports.DailyReport
  alias VutuvWeb.EmailComponents
  alias VutuvWeb.EmailText
  alias VutuvWeb.Plug.Locale

  # The visible From ({name, address}) on every message. Per-installation:
  # config :vutuv, :mailer_from, overridable at boot via MAILER_FROM_NAME /
  # MAILER_FROM_ADDRESS (config/runtime.exs).
  defp from_address, do: Application.fetch_env!(:vutuv, :mailer_from)

  defp from_domain, do: from_address() |> elem(1) |> String.split("@") |> List.last()

  # The operator of this installation: receives the daily report, the ad
  # bookings and the account-deleted notices — never a member-facing address.
  # config :vutuv, :operator_recipient, overridable via OPERATOR_NAME /
  # OPERATOR_EMAIL (config/runtime.exs).
  defp operator_recipient, do: Application.fetch_env!(:vutuv, :operator_recipient)

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

  # Opt-in headers for bulk mail only (see bulk_headers/1). Built at call time
  # because the unsubscribe mailto follows the configured From address.
  defp bulk_header_list do
    [
      {"Precedence", "bulk"},
      {"List-Unsubscribe", "<mailto:#{elem(from_address(), 1)}?subject=unsubscribe>"}
    ]
  end

  @doc """
  Base builder every email starts from. Sets the `From` and the auto-generated
  robot headers, so those live in exactly one place.
  """
  def base_email do
    new()
    |> from(from_address())
    |> stamp_headers()
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
    cond do
      malformed_recipient?(email) ->
        Logger.warning("Dropped email \"#{email.subject}\" to a malformed address")
        {:error, :invalid_recipient}

      suppressed?(email) ->
        Logger.info("Suppressed email \"#{email.subject}\" to undeliverable address")
        :suppressed

      true ->
        email
        |> stamp_headers()
        |> Vutuv.Mailer.deliver()
    end
  end

  @doc """
  Runs `fun` (a 0-arity function that builds and delivers mail) off the calling
  process: as a supervised `Vutuv.TaskSupervisor` task in production, or inline
  in tests (`config :vutuv, :async_email, false`, so the Swoosh test adapter's
  message reaches the asserting process). Returns `:ok`.

  The single owner of the async-email gate, so its shape (the env flag + the
  supervised spawn) lives in one place instead of being copied into every
  context that mails off the request path. Callers keep their own per-site
  logging / return value around this core — this only decides where `fun` runs.
  """
  def deliver_async(fun) when is_function(fun, 0) do
    if Application.get_env(:vutuv, :async_email, true) do
      {:ok, _pid} = Task.Supervisor.start_child(Vutuv.TaskSupervisor, fun)
    else
      fun.()
    end

    :ok
  end

  # gen_smtp's puny-encoding raises on whitespace in a recipient address (one
  # legacy address took down a whole newsletter broadcast that way), so the
  # chokepoint drops such mail with an error tuple instead of letting every
  # caller crash. Deliberately narrow - whitespace or empty only; anything
  # else malformed still gets an orderly {:error, _} from the adapter itself.
  defp malformed_recipient?(%Swoosh.Email{to: to}) when is_list(to) and to != [] do
    Enum.any?(to, fn
      {_name, address} when is_binary(address) -> address == "" or address =~ ~r/\s/
      _other -> true
    end)
  end

  defp malformed_recipient?(_email), do: false

  # The idempotent header-stamping pipeline shared by `base_email/0` and the
  # `deliver/1` chokepoint, so the robot headers, bounce envelope sender and
  # Message-Id are applied in exactly one place (each step is a no-op when its
  # header is already present).
  defp stamp_headers(email) do
    email
    |> robot_headers()
    |> envelope_sender()
    |> message_id()
  end

  defp suppressed?(%Swoosh.Email{private: %{user_initiated: true}}), do: false

  defp suppressed?(%Swoosh.Email{to: to}) when is_list(to) and to != [] do
    Enum.all?(to, fn {_name, address} -> Bounces.suppressed?(address) end)
  end

  defp suppressed?(_email), do: false

  # The Swoosh SMTP adapter uses the Sender header as the SMTP envelope
  # sender (MAIL FROM), so every DSN comes back to the one bounce mailbox
  # production Postfix pipes into POST /webhooks/bounces. The visible From
  # stays no-reply@vutuv.de.
  defp envelope_sender(email), do: header(email, "Sender", bounce_address())

  defp bounce_address, do: Application.fetch_env!(:vutuv, :bounce_address)

  # A globally-unique RFC 5322 Message-ID whose right-hand side is the From
  # domain (vutuv.de). Without one set here, the Swoosh SMTP adapter lets
  # gen_smtp fall back to "<token@<hostname>>", the machine's bare short
  # hostname (e.g. "@bremen2"): a non-FQDN id that costs a point on spam
  # scoring. Idempotent: mail built through base_email keeps that id when it
  # reaches the deliver/1 chokepoint; only a message that arrived without one
  # (a builder that skipped the base) gets stamped there.
  defp message_id(%Swoosh.Email{headers: %{"Message-ID" => _}} = email), do: email

  defp message_id(email),
    do: header(email, "Message-ID", "<#{Vutuv.UUIDv7.generate()}@#{from_domain()}>")

  @doc """
  Adds the bulk-only headers (`Precedence: bulk`, `List-Unsubscribe`). These are
  **not** safe for one-to-one transactional mail because `Precedence: bulk` can
  hurt inbox placement, so they are opt-in and applied only to bulk mail.
  """
  def bulk_headers(%Swoosh.Email{} = email), do: put_headers(email, bulk_header_list())

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

    build_email(user, email, "verification_confirmation", %{}, fn ->
      gettext("vutuv Account verified")
    end)
  end

  # Longest message excerpt quoted in the unread-notification email. A DM may
  # run to Message.max_body_length (10k chars); the email is only a nudge, so
  # quote an opening excerpt and let the member read the rest on vutuv.
  @message_excerpt_length 600

  @doc """
  The debounced "you have an unread message" notice (see
  `Vutuv.Chat.send_unread_notifications/0`). Names the sender by @handle only
  (system text never uses clear names) and quotes `message_body`, the first
  unread message of the burst (the DM that triggered the email), so the member
  can read it without opening the app. The copy also explains that only that
  first message is mailed, to keep the notifications quiet. The caller passes
  the recipient's address (it already looked it up to decide whether to send at
  all) and the message body.
  """
  def unread_messages_email(email, user, other, conversation_id, message_body) do
    locale = get_locale(user.locale)
    unsubscribe_url = VutuvWeb.UnsubscribeToken.url(user)

    base_email()
    |> to({VutuvWeb.UserHelpers.name_for_email_to_field(user), email})
    |> unsubscribe_headers(unsubscribe_url)
    |> subject(
      recipient_subject(locale, fn ->
        gettext("New message from @%{slug} on vutuv",
          slug: other.username
        )
      end)
    )
    |> render_bodies("unread_messages", locale, %{
      user: user,
      other_slug: other.username,
      conversation_id: conversation_id,
      message_body: message_excerpt(message_body),
      # The recipient's own settings drive the copy: whether they are told this
      # is the only email for the burst or that every message is mailed, and the
      # deep link where they can change that (and the delay).
      each_message?: user.dm_email_each_message?,
      settings_url: "#{public_url()}#{user.username}/settings/notifications",
      url: public_url(),
      unsubscribe_url: unsubscribe_url
    })
  end

  # Opening excerpt of a quoted message: the whole thing when short, otherwise
  # the first @message_excerpt_length graphemes with a trailing ellipsis. A nil
  # body (a moderator deleted the message between selection and send) drops the
  # quote rather than rendering an empty box.
  defp message_excerpt(nil), do: nil

  defp message_excerpt(body) do
    if String.length(body) > @message_excerpt_length do
      String.trim_trailing(String.slice(body, 0, @message_excerpt_length)) <> "…"
    else
      body
    end
  end

  @doc """
  "@handle started following you" notice. Opt-in: only sent when the recipient
  set `email_on_follower?` (its own one-click unsubscribe switches just that
  back off). Names the follower by @handle only — system text never uses clear
  names. The caller passes the recipient's address.
  """
  def new_follower_email(email, user, follower) do
    notification_email(
      email,
      user,
      "new_follower",
      :email_on_follower?,
      fn -> gettext("@%{slug} started following you on vutuv", slug: follower.username) end,
      %{actor_username: follower.username}
    )
  end

  @doc """
  "@handle endorsed you for <tag>" notice. Opt-in via `email_on_endorsement?`.
  """
  def endorsement_email(email, user, endorser, tag_name) do
    notification_email(
      email,
      user,
      "endorsement",
      :email_on_endorsement?,
      fn -> gettext("@%{slug} endorsed you on vutuv", slug: endorser.username) end,
      %{actor_username: endorser.username, tag_name: tag_name}
    )
  end

  # The shared shape of the opt-in activity notices: localized subject, the
  # matching per-locale text template (always handed `user`, `url` and
  # `unsubscribe_url`), and the per-type one-click unsubscribe header/footer.
  defp notification_email(email, user, template_base, field, subject_fun, extra_assigns) do
    locale = get_locale(user.locale)
    unsubscribe_url = VutuvWeb.UnsubscribeToken.url(user, field)

    base_email()
    |> to({VutuvWeb.UserHelpers.name_for_email_to_field(user), email})
    |> unsubscribe_headers(unsubscribe_url)
    |> subject(recipient_subject(locale, subject_fun))
    |> render_bodies(
      template_base,
      locale,
      Map.merge(%{user: user, url: public_url(), unsubscribe_url: unsubscribe_url}, extra_assigns)
    )
  end

  # RFC 8058 one-click unsubscribe for notification (non-transactional) mail:
  # the HTTPS form is what Gmail/Yahoo's unsubscribe buttons POST to, the
  # mailto is the fallback for everything else. Transactional mail (PINs,
  # moderation notices) must NOT carry these - it cannot be opted out of.
  defp unsubscribe_headers(email, url) do
    mailto = "mailto:#{elem(from_address(), 1)}?subject=unsubscribe"

    email
    |> header("List-Unsubscribe", "<#{url}>, <#{mailto}>")
    |> header("List-Unsubscribe-Post", "List-Unsubscribe=One-Click")
  end

  ## Newsletters (see Vutuv.Newsletters, the only caller)

  @doc """
  An admin newsletter ("Rundbrief"). Unlike the templated mails, the body is
  composed by an admin and arrives here already rendered (inline-styled HTML +
  plain text, merge variables substituted) from `Vutuv.Newsletters`; this only
  wraps it in the shared email chrome and sets the headers. It is bulk mail, so
  it carries `Precedence: bulk`; a `broadcast` also carries the tokenized
  one-click unsubscribe, while a `test` send passes `unsubscribe_url: nil`.
  """
  def newsletter_email(%{
        to_name: to_name,
        to_email: to_email,
        subject: subject_line,
        locale: locale,
        content_html: content_html,
        content_text: content_text,
        unsubscribe_url: unsubscribe_url
      }) do
    base_email()
    |> to({to_name, to_email})
    |> bulk_headers()
    |> newsletter_unsubscribe(unsubscribe_url)
    |> subject(subject_line)
    |> html_body(
      EmailComponents.render_to_string("newsletter_#{locale}.html", %{
        preheader: subject_line,
        locale: locale,
        content_html: content_html,
        unsubscribe_url: unsubscribe_url
      })
    )
    |> text_body(
      EmailText.render("newsletter_#{locale}.text", %{
        locale: locale,
        content_text: content_text,
        unsubscribe_url: unsubscribe_url
      })
    )
  end

  defp newsletter_unsubscribe(email, nil), do: email
  defp newsletter_unsubscribe(email, url), do: unsubscribe_headers(email, url)

  @doc """
  Invites a non-member to join, on behalf of `inviter` (see `Vutuv.Invitations`).

  Unlike every other builder the recipient has no account, so the language is
  the one the inviter chose (not a recipient `user.locale`) and the greeting is
  built inline in the template rather than from a `%User{}`. The link opens the
  sign-up form prefilled with the data the inviter entered (`prefill`); an
  optional personal `message` is quoted in the body when present.

  Deliberately not flagged `user_initiated`: bounce suppression should still
  apply, so a previously-undeliverable address is not mailed again.
  """
  def invitation_email(%{
        inviter: %Vutuv.Accounts.User{} = inviter,
        to_email: to_email,
        locale: locale,
        message: message,
        prefill: prefill
      }) do
    locale = get_locale(locale)
    inviter_name = VutuvWeb.UserHelpers.full_name(inviter)

    base_email()
    |> to({invitee_name(prefill, to_email), to_email})
    |> subject(
      recipient_subject(locale, fn ->
        gettext("%{name} invited you to vutuv", name: inviter_name)
      end)
    )
    |> render_bodies("invitation", locale, %{
      greeting: invitation_greeting(locale, prefill),
      inviter_name: inviter_name,
      inviter_url: public_url() <> inviter.username,
      message: message,
      invite_url: invitation_signup_url(prefill),
      url: public_url()
    })
  end

  # The invited person's salutation. Reuses the app-wide greeting convention
  # (VutuvWeb.UserHelpers.email_greeting/1) so a known gender + surname yields a
  # personal "Guten Tag Frau Musterfrau" / "Dear …"; without them it degrades to
  # the plain greeting. Built from a throwaway struct — the recipient has no
  # account.
  defp invitation_greeting(locale, prefill) do
    VutuvWeb.UserHelpers.email_greeting(%Vutuv.Accounts.User{
      locale: locale,
      gender: prefill["gender"],
      first_name: prefill["first_name"],
      last_name: prefill["last_name"]
    })
  end

  # The invite link: the landing page prefilled from the sign-up fields the
  # inviter entered. Vutuv.Invitations.PrefillToken packs them into one compact
  # `i=` token (shorter than spelling the fields out, and it keeps the invitee's
  # name and address out of the URL in the clear); VutuvWeb.PageController.index
  # reads it back.
  defp invitation_signup_url(prefill) do
    case PrefillToken.query(prefill) do
      "" -> public_url()
      query -> public_url() <> "?" <> query
    end
  end

  defp invitee_name(prefill, to_email) do
    name =
      [prefill["first_name"], prefill["last_name"]]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")

    if name == "", do: to_email, else: name
  end

  ## Login security (see Vutuv.Sessions.start_session/3, the only caller)

  @doc """
  Alerts the account owner that their account was just signed into in a way
  worth a second look — a new device/browser or a login from an unfamiliar
  location (issue #786). Carries the device, approximate location, source IP
  and time so the owner can recognize (or not) the login, and deep-links to
  their signed-in-devices page so a "this wasn't me" is one click away (issue
  #794). Transactional security mail, so it carries no unsubscribe and is built
  with `build_email` (subject to bounce suppression, never user-initiated).
  """
  def security_alert_email(%Vutuv.Accounts.User{} = user, email, session, reasons) do
    locale = get_locale(user.locale)

    assigns = %{
      device: Vutuv.Sessions.device_summary(session.user_agent),
      location: session.approx_location,
      ip: session.ip_address,
      when_text: format_login_time(session.inserted_at),
      reason_lines: security_reason_lines(reasons, locale),
      devices_url: "#{public_url()}#{user.username}/settings"
    }

    build_email(user, email, "security_alert", assigns, fn ->
      gettext("New sign-in to your vutuv account")
    end)
  end

  # The login time as plain UTC ("2026-06-15 05:41 UTC"). The server runs UTC and
  # we do not know the recipient's timezone, so stating the zone is honest.
  # strftime accepts both the naive (timestamps) and aware structs.
  defp format_login_time(at) when is_struct(at, NaiveDateTime) or is_struct(at, DateTime),
    do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  defp format_login_time(_), do: nil

  # The reasons, rendered in the recipient's language (the body template is
  # per-language, but the reason atoms are shared, so they are localized here
  # the same way the subject is).
  defp security_reason_lines(reasons, locale) do
    Gettext.with_locale(VutuvWeb.Gettext, locale, fn ->
      Enum.map(reasons, &security_reason_text/1)
    end)
  end

  defp security_reason_text(:new_device),
    do: gettext("This is the first sign-in we have seen from this device or browser.")

  defp security_reason_text(:concurrent),
    do: gettext("Another session was already active on your account.")

  defp security_reason_text(:suspicious_location),
    do: gettext("The location looks different from where you usually sign in.")

  ## Ad bookings (see Vutuv.Ads.book_ad/2, the only caller)

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
    |> to(operator_recipient())
    |> subject("vutuv Anzeigenbuchung für den #{Calendar.strftime(ad.day, "%d.%m.%Y")}")
    |> render_bodies("ad_booking", "de", %{
      ad: ad,
      booker: booker,
      booker_email: Vutuv.Accounts.first_email_value(booker),
      billing_address: billing_address(ad),
      price: format_euro_cents(ad.price_cents),
      url: public_url()
    })
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

  ## Operator notices (fixed German recipient, no member ever receives them)

  @doc """
  The operator's daily report: confirmed-by-PIN new registrations, the day's
  posts/reposts/likes/bookmarks, and the day's email-deliverability events
  (`Vutuv.Reports.DailyReport`). The subject lists only the non-zero numbers.
  Fixed German recipient and template, like the ad-booking notice; the caller
  only sends it for days that actually had activity.
  """
  def daily_report_email(%DailyReport{} = report) do
    base_email()
    |> to(operator_recipient())
    |> subject(DailyReport.email_subject(report))
    |> render_bodies("daily_report", "de", %{report: report, url: public_url()})
  end

  @doc """
  Operator notice that an admin deleted a member account. Goes to the operator
  (the configured `:operator_recipient`) and **never** to the deleted member: it records what
  was removed - the account's name, @handle, id, every email address and phone
  number, the post count and the join date, all captured before the cascade -
  plus the exact deletion timestamp (UTC and Europe/Berlin wall-clock). Fixed
  German recipient and template, like the daily report. The only caller is
  `Vutuv.Accounts.admin_delete_user/1`, which snapshots the account before it
  is gone and hands the map here.
  """
  def account_deleted_notice(snapshot) do
    base_email()
    |> to(operator_recipient())
    |> subject("vutuv: Konto @#{snapshot.username} gelöscht")
    |> render_bodies("account_deleted_notice", "de", %{account: deletion_display(snapshot)})
  end

  # The account snapshot enriched with the pre-formatted timestamp strings the
  # template renders, so the body template stays logic-free. The stored
  # instants are UTC; the operator sits in Germany, so the deletion time is
  # shown in both UTC and Europe/Berlin wall-clock (via Vutuv.BerlinTime, which
  # carries no tzdata dependency).
  defp deletion_display(snapshot) do
    Map.merge(snapshot, %{
      deleted_at_utc: Calendar.strftime(snapshot.deleted_at, "%d.%m.%Y %H:%M:%S UTC"),
      deleted_at_berlin:
        snapshot.deleted_at
        |> Vutuv.BerlinTime.naive()
        |> Calendar.strftime("%d.%m.%Y %H:%M:%S Uhr"),
      joined_at_display: Calendar.strftime(snapshot.joined_at, "%d.%m.%Y")
    })
  end

  ## Company pages (see Vutuv.Companies)

  @doc "Operator notice: a company page was newly verified (a human reviews each one)."
  def company_verified_notice(company, domain) do
    company_operator_notice(
      :verified,
      company,
      domain,
      "vutuv: Firmenseite verifiziert - #{company.name}"
    )
  end

  @doc "Operator notice: a company lost its last verified domain and fell back to pending."
  def company_unverified_notice(company, domain) do
    company_operator_notice(
      :unverified,
      company,
      domain,
      "vutuv: Firmenseite nicht mehr verifiziert - #{company.name}"
    )
  end

  # Fixed German recipient and template, like the other operator notices.
  defp company_operator_notice(kind, company, domain, subject_line) do
    base_email()
    |> to(operator_recipient())
    |> subject(subject_line)
    |> render_bodies("company_operator_notice", "de", %{
      kind: kind,
      company: company,
      domain: domain,
      page_url: "#{public_url()}companies/#{company.slug}",
      url: public_url()
    })
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
    |> with_appeal_reply_to()
  end

  # The From (no-reply@) is not read. The deactivation mail is the one message
  # whose copy invites a reply ("appeal by replying to this email"), so route
  # that reply to the monitored legal contact. No other mail sets a Reply-To,
  # so a reply to it bounces off no-reply@ as intended.
  defp with_appeal_reply_to(email), do: reply_to(email, appeal_reply_to())

  defp appeal_reply_to, do: Application.fetch_env!(:vutuv, :appeal_reply_to)

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
      owner_slug: case_record.owner.username,
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
    |> render_bodies(
      template_base,
      locale,
      Map.merge(%{user: user, url: public_url()}, extra_assigns)
    )
  end

  # Renders the multipart bodies for a templated email: the text/plain body
  # (the `*.text.eex` templates) and the text/html alternative (the
  # `*.html.heex` bodies through VutuvWeb.EmailComponents). Both come from the
  # same assigns, with the recipient locale merged in so the HTML chrome can
  # localize. Setting both makes Swoosh send multipart/alternative.
  defp render_bodies(email, template_base, locale, assigns) do
    assigns = Map.put(assigns, :locale, locale)

    email
    |> text_body(EmailText.render("#{template_base}_#{locale}.text", assigns))
    |> html_body(EmailComponents.render_to_string("#{template_base}_#{locale}.html", assigns))
  end

  # The configured canonical host (with a trailing slash), e.g.
  # "https://vutuv.de/" — every URL an email names builds on it.
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
