defmodule Vutuv.Notifications.Emailer do
  @moduledoc """
  Builds and delivers every outbound vutuv email.

  All mail vutuv sends is machine-generated (login PINs, registration, email
  confirmation, account deletion, payment info, invoices, birthday reminders),
  so two things are guaranteed here in exactly one place:

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
  require Ecto.Query
  alias Vutuv.Repo
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
  hurt inbox placement, so they are opt-in and applied only to bulk mail such as
  the birthday reminder.
  """
  def bulk_headers(%Swoosh.Email{} = email), do: put_headers(email, @bulk_headers)

  def login_email(pin, email, %Vutuv.Accounts.User{validated?: false} = user) do
    gen_email(
      pin,
      email,
      user,
      "registration_email_#{get_locale(user.locale)}",
      Gettext.gettext(VutuvWeb.Gettext, "Confirm your vutuv account")
    )
  end

  def login_email(pin, email, user) do
    gen_email(
      pin,
      email,
      user,
      "login_email_#{get_locale(user.locale)}",
      Gettext.gettext(VutuvWeb.Gettext, "Login to vutuv")
    )
  end

  def email_creation_email(pin, email, user) do
    gen_email(
      pin,
      email,
      user,
      "email_creation_email_#{get_locale(user.locale)}",
      Gettext.gettext(VutuvWeb.Gettext, "Confirm your email")
    )
  end

  def user_deletion_email(pin, email, user) do
    gen_email(
      pin,
      email,
      user,
      "user_deletion_email_#{get_locale(user.locale)}",
      Gettext.gettext(VutuvWeb.Gettext, "Confirm your account deletion")
    )
  end

  def payment_information_email(recruiter_subscription, user, email) do
    recuiter_package =
      Vutuv.Repo.get(
        Vutuv.Recruiting.RecruiterPackage,
        recruiter_subscription.recruiter_package_id
      )

    template = "payment_information_email_#{get_locale(user.locale)}"
    accounting_email = accounting_email()

    base_email()
    |> to({VutuvWeb.UserHelpers.name_for_email_to_field(user), email})
    |> bcc(accounting_email)
    |> subject(
      Gettext.gettext(VutuvWeb.Gettext, "Order") <>
        " \"#{recuiter_package.name}\" " <> Gettext.gettext(VutuvWeb.Gettext, "subscription")
    )
    |> text_body(
      VutuvWeb.EmailText.render("#{template}.text", %{
        recuiter_package: recuiter_package,
        recruiter_subscription: recruiter_subscription,
        user: user
      })
    )
  end

  def issue_invoice(recruiter_subscription, user, _email) do
    accounting_email = accounting_email()

    if accounting_email do
      recuiter_package =
        Vutuv.Repo.get(
          Vutuv.Recruiting.RecruiterPackage,
          recruiter_subscription.recruiter_package_id
        )

      base_email()
      |> to(accounting_email)
      |> subject("Rechnung: #{recuiter_package.name} für #{user.first_name} #{user.last_name}")
      |> text_body(
        VutuvWeb.EmailText.render("trigger_recruiter_subscription_invoice.text", %{
          recruiter_subscription: recruiter_subscription,
          recuiter_package: recuiter_package,
          user: user
        })
      )
    end
  end

  def verification_notice(user) do
    email = primary_email(user)
    template = "verification_confirmation_#{get_locale(user.locale)}"

    base_email()
    |> to({VutuvWeb.UserHelpers.name_for_email_to_field(user), email})
    |> subject(Gettext.gettext(VutuvWeb.Gettext, "vutuv Account verified"))
    |> text_body(VutuvWeb.EmailText.render("#{template}.text", %{user: user}))
  end

  def birthday_reminder(user, birthday_childs, future_birthday_childs) do
    {{today_year, _month, _day}, {_, _, _}} = :calendar.local_time()

    name_list =
      for(birthday_child <- birthday_childs) do
        %Date{year: birthday_year} = birthday_child.birthdate

        case birthday_year do
          1900 ->
            VutuvWeb.UserHelpers.full_name(birthday_child)

          _ ->
            "#{VutuvWeb.UserHelpers.full_name(birthday_child)} (#{today_year - birthday_year})"
        end
      end

    full_names_with_age = Enum.join(name_list, ", ")

    truncated_subject =
      if String.length(full_names_with_age) > 50 do
        "#{String.slice(full_names_with_age, 0..45)} ..."
      else
        full_names_with_age
      end

    template = "birthday_reminder_#{get_locale(user.locale)}"

    email = primary_email(user)

    Gettext.put_locale(VutuvWeb.Gettext, user.locale)

    base_email()
    |> to({VutuvWeb.UserHelpers.name_for_email_to_field(user), email})
    |> bulk_headers()
    |> subject("#{Gettext.gettext(VutuvWeb.Gettext, "Birthday")}: #{truncated_subject}")
    |> text_body(
      VutuvWeb.EmailText.render("#{template}.text", %{
        user: user,
        birthday_childs: birthday_childs,
        future_birthday_childs: future_birthday_childs
      })
    )
  end

  def enrichment_trigger(_user) do
    nil
  end

  defp gen_email(pin, email, user, template, email_subject) do
    url = Application.get_env(:vutuv, VutuvWeb.Endpoint)[:public_url]

    base_email()
    |> to({VutuvWeb.UserHelpers.name_for_email_to_field(user), email})
    |> subject(email_subject)
    |> text_body(
      VutuvWeb.EmailText.render("#{template}.text", %{
        pin: pin,
        url: url,
        user: user
      })
    )
  end

  defp robot_headers(email), do: put_headers(email, @robot_headers)

  defp put_headers(email, headers) do
    Enum.reduce(headers, email, fn {name, value}, acc -> header(acc, name, value) end)
  end

  defp primary_email(user) do
    Repo.one(
      Ecto.Query.from(e in Vutuv.Accounts.Email,
        where: e.user_id == ^user.id,
        limit: 1,
        select: e.value
      )
    )
  end

  defp accounting_email do
    Application.fetch_env!(:vutuv, VutuvWeb.Endpoint)[:accounting_email]
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
