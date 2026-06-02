defmodule Vutuv.Notifications.Emailer do
  @moduledoc false

  import Swoosh.Email
  require Ecto.Query
  alias Vutuv.Repo
  alias VutuvWeb.Plug.Locale

  @from_address {"vutuv", "info@vutuv.de"}

  def login_email({link, pin}, email, %Vutuv.Accounts.User{validated?: false} = user) do
    gen_email(
      link,
      pin,
      email,
      user,
      "registration_email_#{get_locale(user.locale)}",
      Gettext.gettext(VutuvWeb.Gettext, "Confirm your vutuv account")
    )
  end

  def login_email({link, pin}, email, user) do
    gen_email(
      link,
      pin,
      email,
      user,
      "login_email_#{get_locale(user.locale)}",
      Gettext.gettext(VutuvWeb.Gettext, "Login to vutuv")
    )
  end

  def fbs_login_email({link, pin}, email, %Vutuv.Accounts.User{validated?: false} = user) do
    gen_email(
      link,
      pin,
      email,
      user,
      "fbs_registration_email_#{get_locale(user.locale)}",
      Gettext.gettext(VutuvWeb.Gettext, "Confirm your vutuv account")
    )
  end

  def fbs_login_email({link, pin}, email, user) do
    gen_email(
      link,
      pin,
      email,
      user,
      "fbs_login_email_#{get_locale(user.locale)}",
      Gettext.gettext(VutuvWeb.Gettext, "Login to vutuv")
    )
  end

  def email_creation_email({link, pin}, email, user) do
    gen_email(
      link,
      pin,
      email,
      user,
      "email_creation_email_#{get_locale(user.locale)}",
      Gettext.gettext(VutuvWeb.Gettext, "Confirm your email")
    )
  end

  def user_deletion_email({link, pin}, email, user) do
    gen_email(
      link,
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

    new()
    |> to({VutuvWeb.UserHelpers.name_for_email_to_field(user), email})
    |> bcc(accounting_email)
    |> from(@from_address)
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

      new()
      |> to(accounting_email)
      |> from(@from_address)
      |> subject("Rechnung: #{recuiter_package.name} für #{user.first_name} #{user.last_name}")
      |> text_body(
        VutuvWeb.EmailText.render("trigger_recruiter_subscription_invoice.text", %{
          recruiter_subscription: recruiter_subscription,
          recuiter_package: recuiter_package,
          user: user
        })
      )
      |> Vutuv.Mailer.deliver()
    end
  end

  def verification_notice(user) do
    email = primary_email(user)
    template = "verification_confirmation_#{get_locale(user.locale)}"

    new()
    |> to({VutuvWeb.UserHelpers.name_for_email_to_field(user), email})
    |> from(@from_address)
    |> subject(Gettext.gettext(VutuvWeb.Gettext, "vutuv Account verified"))
    |> text_body(VutuvWeb.EmailText.render("#{template}.text", %{user: user}))
    |> Vutuv.Mailer.deliver()
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

    new()
    |> to({VutuvWeb.UserHelpers.name_for_email_to_field(user), email})
    |> from(@from_address)
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

  defp gen_email(link, pin, email, user, template, email_subject) do
    url = Application.get_env(:vutuv, VutuvWeb.Endpoint)[:public_url]

    new()
    |> to({VutuvWeb.UserHelpers.name_for_email_to_field(user), email})
    |> from(@from_address)
    |> subject(email_subject)
    |> text_body(
      VutuvWeb.EmailText.render("#{template}.text", %{
        link: link,
        pin: pin,
        url: url,
        user: user
      })
    )
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
