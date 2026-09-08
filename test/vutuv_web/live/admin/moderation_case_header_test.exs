defmodule VutuvWeb.Admin.ModerationCaseHeaderTest do
  @moduledoc """
  The two things an admin reads off the top of a case page that were not true
  (issue #2069).

  The header printed the report time and the owner's deadline as bare machine
  stamps in universal time, two hours behind the same moment in the history
  directly beneath it — an admin reading a deadline off the header was two
  hours wrong, in the wrong direction. And the good-faith declaration a
  copyright notice is only accepted with was validated and thrown away, so
  nothing on the page said it had been made.

  German (`Accept-Language: de-DE,de`), because that is the language the queue
  is worked in and because a fuzzy-filled msgid fails no build. The admin here
  carries their own time zone, which is what makes the server text final and
  this assertion deterministic rather than a browser's job.
  """

  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Moderation
  alias Vutuv.Moderation.Case

  # A summer instant, so Berlin is two hours ahead of the stamp in the database
  # — the exact gap the issue reports.
  @reported_at ~N[2026-07-15 01:24:00]
  @deadline_at ~N[2026-07-18 01:26:00]

  setup %{conn: conn} do
    {admin_conn, admin} = create_and_login_admin(conn)

    admin
    |> Ecto.Changeset.change(%{time_zone: "Europe/Berlin", date_region: "DE"})
    |> Repo.update!()

    owner = insert(:activated_user)
    insert(:email, user: owner)
    reporter = insert(:activated_user)
    insert(:email, user: reporter)

    {:ok, conn: admin_conn, owner: owner, reporter: reporter}
  end

  # `recycle/1` first: the login already sent a response on this conn, and a
  # header cannot be put on a sent one.
  defp german(conn),
    do: conn |> recycle() |> put_req_header("accept-language", "de-DE,de;q=0.9")

  defp copyright_case!(%{owner: owner, reporter: reporter}) do
    post = insert(:post, user: owner)

    {:ok, %Case{} = case_record} =
      Moderation.report_content(reporter, post, %{
        "category" => "copyright",
        "note" => "Der Text ist meiner, das Original steht auf example.com/text.",
        "good_faith?" => "true"
      })

    case_record
  end

  defp pin_clock!(%Case{id: id}) do
    Repo.update_all(
      from(c in Case, where: c.id == ^id),
      set: [inserted_at: @reported_at, owner_deadline_at: @deadline_at]
    )
  end

  defp show(conn, %Case{id: id}),
    do: conn |> german() |> get(~p"/admin/moderation/#{id}") |> html_response(200)

  describe "the header clock" do
    # Both labels are new msgids, and `gettext.extract --merge` fuzzy-filled
    # this exact pair: "Reported" came back as "Melder" (the reporter, the
    # other party entirely) and "Owner deadline" still carried the retired
    # `%{date}`. A short label is the likeliest to be fuzzy-matched and the
    # least likely to be noticed, so both are pinned by name — a timestamp
    # assertion beside them would stay green through either mistranslation.
    test "names both stamps in German", context do
      case_record = copyright_case!(context)
      pin_clock!(case_record)

      html = show(context.conn, case_record)

      assert html =~ "Gemeldet:"
      assert html =~ "Frist des Besitzers:"

      refute html =~ "Melder:"
      refute html =~ "%{date}"
    end

    test "reads in the admin's own zone, like the history beneath it", context do
      case_record = copyright_case!(context)
      pin_clock!(case_record)

      html = show(context.conn, case_record)

      assert html =~ "15.07.2026 03:24"
      assert html =~ "18.07.2026 03:26"

      # The stamp as it sits in the database is what an admin was reading, and
      # it must not be the visible text any more.
      refute html =~ "2026-07-15 01:24"
      refute html =~ "2026-07-18 01:26"

      # The `<time datetime>` half is what gets an admin who never set a zone
      # their browser's, instead of a bare UTC stamp.
      assert html =~ ~s(datetime="2026-07-15T01:24:00Z")
    end
  end

  describe "the good-faith declaration" do
    test "is on the case, not only in the changeset", context do
      case_record = copyright_case!(context)

      assert show(context.conn, case_record) =~ "in gutem Glauben erklärt"
    end

    test "is absent where none was made", %{owner: owner, reporter: reporter, conn: conn} do
      post = insert(:post, user: owner)
      {:ok, case_record} = Moderation.report_content(reporter, post, %{"category" => "spam"})

      refute show(conn, case_record) =~ "in gutem Glauben erklärt"
    end
  end
end
