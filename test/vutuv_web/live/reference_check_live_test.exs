defmodule VutuvWeb.ReferenceCheckLiveTest do
  @moduledoc """
  The review panel on one Arbeitszeugnis (`VutuvWeb.ReferenceCheckLive`),
  embedded off-router by the editor, so it is mounted here the way it is
  mounted there: from the cookie's `session_token` plus the entry's id.

  What is guarded is the **wording before the member commits**. The panel used
  to quote a duration next to the button ("Usually about 4 minutes"), computed
  from the median of past runs plus whatever sits in the queue. It is a promise
  made before there is anything to be held to, and it was wrong often enough to
  be worth nothing: one long document, or a model that has gone cold, doubles
  it. The states that follow keep their own account of the wait, because there
  the member is shown the queue position the number is built on.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Vutuv.Factory

  alias Vutuv.References.Check
  alias Vutuv.References.Checks
  alias Vutuv.Repo
  alias VutuvWeb.JobReferenceHTML

  defp mount_panel(conn, user, reference) do
    live_isolated(conn, VutuvWeb.ReferenceCheckLive,
      session: shell_session(user, %{"job_reference_id" => reference.id})
    )
  end

  # A finished run is what gives the estimate something to compute from, so
  # every "no duration is quoted" claim has to be made with one in the table.
  defp finished_check(user, duration_ms) do
    Repo.insert!(%Check{
      job_reference_id: insert(:job_reference, user: user).id,
      user_id: user.id,
      status: "done",
      duration_ms: duration_ms,
      queued_at: DateTime.utc_now(:second)
    })
  end

  describe "before the review is queued" do
    test "the button quotes no duration, even with finished runs to go on", %{conn: conn} do
      user = insert_activated_user()
      reference = insert(:job_reference, user: user)
      for ms <- [240_000, 250_000, 230_000], do: finished_check(user, ms)

      {:ok, view, _html} = mount_panel(conn, user, reference)
      html = render(view)

      assert html =~ "Decode this reference"
      refute html =~ "Usually about"
      refute html =~ "Takes a few minutes"
    end

    # The one thing that line still says, and the reason it exists: a Zeugnis
    # is graded here and the grade stays private, published entry or not.
    test "the button keeps the privacy line beside it", %{conn: conn} do
      user = insert_activated_user()
      reference = insert(:job_reference, user: user)

      {:ok, view, _html} = mount_panel(conn, user, reference)

      assert render(view) =~ "Only you see the result."
    end
  end

  # Both wordings name the allowance and say when the member is free again.
  # The first is exact, from the rolling window; the second is the fallback for
  # a member with nothing left in the window to count from, and it still gives
  # a time rather than "please try again later", which is not something anybody
  # can plan around.
  describe "the allowance is used up" do
    test "the message names the limit and the wait", %{conn: conn} do
      user = insert_activated_user()

      for _ <- 1..Checks.daily_limit(),
          do: {:ok, _} = Checks.enqueue(insert(:job_reference, user: user))

      reference = insert(:job_reference, user: user)

      {:ok, view, _html} = mount_panel(conn, user, reference)
      html = view |> element("button[phx-click='check']") |> render_click()

      assert html =~ "#{Checks.daily_limit()} reviews"
      assert html =~ "possible again in about"
    end

    test "the fallback names the limit and the window instead of 'later'", %{conn: _conn} do
      message = JobReferenceHTML.rate_limit_message(nil)

      assert message =~ "#{Checks.daily_limit()} reviews"
      assert message =~ "24 hours"
      refute message =~ "later"
    end
  end

  describe "once it is queued" do
    test "the panel says where in the queue the member stands", %{conn: conn} do
      user = insert_activated_user()
      reference = insert(:job_reference, user: user)
      {:ok, _check} = Checks.enqueue(reference)

      {:ok, view, _html} = mount_panel(conn, user, reference)

      assert render(view) =~ "yours is next"
    end
  end
end
