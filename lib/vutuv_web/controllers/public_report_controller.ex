defmodule VutuvWeb.PublicReportController do
  @moduledoc """
  The notice form at `/system/report` — the one report path that needs no
  account (issue #2009).

  A photographer who finds their work on a post here is not a member, so the
  in-app `VutuvWeb.ReportController` (behind `RequireLogin`) was a closed door
  and the Impressum address the only way in. This is the open one: paste the
  address of the content, say what is wrong with it, leave a name and an email,
  declare good faith.

  **Nothing happens on the submit.** `Vutuv.Moderation.file_public_notice/2`
  opens the case as `flagged` — visible to admins, nothing hidden — and mails a
  confirmation link. The freeze, the owner's notice and the urgent admin mail
  all wait for `confirm/2`, so an address nobody can read can never take
  content offline.

  Three things follow from this being an unauthenticated write endpoint that
  sends mail to an address a stranger typed.

  * **It is rate limited** per client IP and per address
    (`VutuvWeb.RateLimit.check_public_notice/2`), and the unique index on
    `(case_id, reporter_email)` means one address gets one receipt per piece of
    content however often it submits — so it cannot be pointed at a third
    party's mailbox as an amplifier.
  * **It is not an existence oracle.** `Vutuv.Moderation.ContentUrl` resolves
    only what an anonymous visitor can already see, so "we could not find that
    page" is the honest answer for a typo, a deleted post, a frozen profile and
    a members-only job posting alike. One consequence is worth knowing: content
    an earlier notice already froze cannot be reported again, and answers the
    same way. That is the right end of the trade — it is off the site and its
    case is with the admins — but it is why a second rights holder is told
    "not found" rather than "already reported". What it does say apart is one
    of **our own pages** (`/impressum`, the house rules, the member
    directory): a correct address carrying nobody's content, which the router
    can answer without telling anybody anything a visitor cannot fetch for
    themselves.
  * **The confirmation is a POST**, not the GET the link lands on. A link
    scanner in a corporate mail gateway follows every URL in an email, and a
    GET that fires a takedown would hand the confirmation to whoever's software
    opened the message first.
  """

  use VutuvWeb, :controller

  alias Vutuv.Moderation
  alias Vutuv.Moderation.ContentUrl
  alias Vutuv.Moderation.Report
  alias Vutuv.Notifications.Emailer
  alias VutuvWeb.ControllerHelpers
  alias VutuvWeb.ErrorHelpers
  alias VutuvWeb.RateLimit

  # `url` prefills the address field, so a Report link on a page can hand the
  # form the picture it is about (issue #2089) instead of asking a journalist to
  # copy it. It is nothing but a value in a text input — the resolve, the rate
  # limit and every check happen on the POST, exactly as they do for a typed
  # address — and it is capped so a crafted link cannot turn the field into a
  # wall of text.
  def new(conn, params) do
    url = params |> Map.get("url", "") |> to_string() |> String.slice(0, 2_000)
    render_form(conn, %Report{}, url, Report.categories(), [])
  end

  def create(conn, %{"report" => params}) when is_map(params) do
    url = params |> Map.get("url", "") |> to_string() |> String.trim()

    # The budget is counted against the **mailbox**, not the spelling: a `+tag`
    # (and a dot at Gmail) otherwise buys a fresh bucket per submission while
    # every one of them lands in the same inbox, which is exactly the
    # amplification the per-address half exists to stop.
    email = params |> Map.get("reporter_email", "") |> to_string() |> Report.canonical_email()

    case RateLimit.check_public_notice(conn, email) do
      :rate_limited ->
        conn
        |> put_status(:too_many_requests)
        |> render_form(struct_from(params), url, Report.categories(), [
          gettext("You have sent us a lot of reports just now. Please try again later.")
        ])

      :ok ->
        submit(conn, params, url)
    end
  end

  def create(conn, _params), do: ControllerHelpers.render_error(conn, 404)

  # The confirmation link's landing page. A GET, so it only *shows* the
  # decision — see the moduledoc on why the takedown may not ride a link a mail
  # gateway can follow.
  def confirm(conn, %{"token" => token}) do
    case Moderation.public_notice_state(token) do
      :confirmed ->
        render(conn, "confirmed.html", page_title: gettext("Report confirmed"))

      :pending ->
        render(conn, "confirm.html", token: token, page_title: gettext("Confirm your report"))

      # Named rather than folded into the 404: somebody holding a link a week
      # old has to be told to send the notice again, not that their address was
      # wrong.
      :expired ->
        conn
        |> put_status(:gone)
        |> render("expired.html", page_title: gettext("This link has expired"))

      :unknown ->
        ControllerHelpers.render_error(conn, 404)
    end
  end

  def confirm_submit(conn, %{"token" => token}) do
    case RateLimit.check_public_notice_confirm(conn) do
      :rate_limited ->
        conn
        |> put_status(:too_many_requests)
        |> render("confirm.html", token: token, page_title: gettext("Confirm your report"))

      :ok ->
        case Moderation.confirm_public_notice(token) do
          {:ok, _state, _report} ->
            render(conn, "confirmed.html", page_title: gettext("Report confirmed"))

          {:error, :expired} ->
            conn
            |> put_status(:gone)
            |> render("expired.html", page_title: gettext("This link has expired"))

          {:error, :invalid} ->
            ControllerHelpers.render_error(conn, 404)
        end
    end
  end

  defp submit(conn, params, url) do
    case ContentUrl.resolve(url) do
      {:error, :foreign_host} ->
        error(conn, params, url, [
          gettext("That address is not on this site. We can only act on content published here.")
        ])

      # A correct address that names one of our own pages. Told apart from the
      # miss below on purpose (issue #2068): "we could not find that page"
      # about `/impressum` sends a rights holder off to re-check a link that
      # was right all along, in the first minute of the one complaint that
      # carries real liability.
      {:error, :not_reportable} ->
        error(conn, params, url, [
          gettext(
            "That address is one of our own pages, not content somebody published here, so there is nothing on it we could act on. Please paste the address of the post, picture, video, profile or job posting itself."
          )
        ])

      {:error, :not_found} ->
        not_found(conn, params, url)

      {:ok, content} ->
        file(conn, params, url, content)
    end
  end

  defp file(conn, params, url, content) do
    type = Moderation.content_type(content)

    # The locale is read here, not in the context: it is per-process web state,
    # and the row keeps it so both mails about this notice — the receipt below
    # and the ruling much later (issue #2011) — are written in the language it
    # was filed in.
    locale = Gettext.get_locale(VutuvWeb.Gettext)

    case Moderation.file_public_notice(content, params, locale) do
      {:ok, _case_record, report, token} ->
        deliver_receipt(conn, report, url, type, token)

        render(conn, "sent.html",
          email: report.reporter_email,
          page_title: gettext("Report sent")
        )

      {:error, :already_reported} ->
        error(conn, params, url, [
          gettext(
            "You already sent us this report. Please use the confirmation link in the email we sent you."
          )
        ])

      {:error, :not_allowed} ->
        not_found(conn, params, url)

      # The category list narrows to what the resolved content type actually
      # offers, so a mismatch ("spam" on a picture) explains itself: the
      # choices that are left are right there under the message.
      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render_form(
          struct_from(params),
          url,
          Moderation.report_categories(content),
          ErrorHelpers.changeset_messages(changeset)
        )
    end
  end

  # Built from the **stored report**, never from the values that were typed.
  # The changeset trims and downcases the address and collapses the name to one
  # line, so the row is the only version of them that is safe to hand to a
  # mailer: a pasted address with a trailing space stored fine, was mailed raw,
  # and the chokepoint dropped it as malformed — the page said the mail had
  # gone, none had, and the honest retry was refused as a duplicate. That
  # complaint was simply dead.
  #
  # Off the request, like every other mail this app sends: production talks
  # real SMTP with retries, and this is the one endpoint a stranger can hold
  # open without an account. Every value travels in the map, the locale off the
  # stored row — per-process state the spawned task does not inherit, so read
  # inside the closure it would quietly send every receipt in English.
  defp deliver_receipt(conn, report, url, type, token) do
    notice = %{
      name: report.reporter_name,
      email: report.reporter_email,
      locale: report.reporter_locale,
      type: type,
      category: report.category,
      content_url: url,
      confirm_url: url(conn, ~p"/system/report/confirm/#{token}")
    }

    Emailer.deliver_async(fn ->
      notice |> Emailer.public_notice_receipt_email() |> Emailer.deliver()
    end)
  end

  # The one answer for a typo, a deleted post, a frozen profile and a
  # members-only job posting alike — see the moduledoc on why they must not be
  # distinguishable.
  defp not_found(conn, params, url) do
    error(conn, params, url, [gettext("We could not find that page. Please check the address.")])
  end

  defp error(conn, params, url, messages) do
    conn
    |> put_status(:unprocessable_entity)
    |> render_form(struct_from(params), url, Report.categories(), messages)
  end

  # The form is sticky through a rejected submit: a notice carries a written
  # explanation the notifier must not lose to a missing checkbox.
  defp struct_from(params) do
    %Report{
      category: params["category"],
      note: params["note"],
      reporter_name: params["reporter_name"],
      reporter_email: params["reporter_email"],
      good_faith?: params["good_faith?"] == "true"
    }
  end

  defp render_form(conn, report, url, categories, errors) do
    render(conn, "new.html",
      page_title: gettext("Report content"),
      report: report,
      url: url,
      categories: categories,
      errors: errors
    )
  end
end
