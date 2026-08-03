defmodule Vutuv.References.ChecksTest do
  @moduledoc """
  The analysis queue: what may enter it, what the member is told while they
  wait, and the two error classes that decide whether a failure is retried
  quietly or shown.

  Drains through `deliver_due/1` with a stubbed analysis function — the
  polling worker stays off in tests (sandbox rule), and no Ollama is involved.

  `async: false`: several tests flip `:reference_checks_*` application env,
  which is global and which `Vutuv.References.Checks` reads.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.Factory

  alias Vutuv.References.Check
  alias Vutuv.References.Checks
  alias Vutuv.Repo

  @result %{
    markdown: "## Kurzbefund\n\nNote 4.",
    model: "qwen3.6:27b",
    skill_version: "3.0.24",
    skill_sha256: String.duplicate("a", 64),
    prompt_tokens: 35_559,
    output_tokens: 3_400,
    duration_ms: 45_000
  }

  setup do
    user = insert(:user)
    %{user: user, reference: insert(:job_reference, user: user)}
  end

  defp put_config(key, value) do
    original = Application.fetch_env(:vutuv, key)
    Application.put_env(:vutuv, key, value)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, key, was)
        :error -> Application.delete_env(:vutuv, key)
      end
    end)
  end

  defp ok_analyzer(result \\ @result), do: fn _body -> {:ok, result} end

  describe "enqueue/1" do
    test "queues a check", %{reference: reference} do
      assert {:ok, check} = Checks.enqueue(reference)
      assert check.status == "pending"
      assert check.job_reference_id == reference.id
      assert check.user_id == reference.user_id
      assert check.queued_at
    end

    test "binds the check to the text it will analyse", %{reference: reference} do
      {:ok, check} = Checks.enqueue(reference)
      assert check.body_fingerprint == Checks.fingerprint(reference.body)
    end

    # A double-clicked button must not buy two slots on a queue where each job
    # holds the model for minutes. The partial unique index is the guarantee.
    test "refuses a second open check for the same Zeugnis", %{reference: reference} do
      {:ok, _first} = Checks.enqueue(reference)
      assert {:error, :already_queued} = Checks.enqueue(reference)
      assert Repo.aggregate(Check, :count) == 1
    end

    test "allows a new check once the previous one finished", %{reference: reference} do
      {:ok, _first} = Checks.enqueue(reference)
      Checks.deliver_due(analyze: ok_analyzer())

      assert {:ok, second} = Checks.enqueue(reference)
      assert second.status == "pending"
    end

    test "refuses a Zeugnis with neither text nor a document", %{user: user} do
      empty = insert(:job_reference, user: user, body: nil)
      assert {:error, :no_body} = Checks.enqueue(empty)

      blank = insert(:job_reference, user: user, body: "   \n ")
      assert {:error, :no_body} = Checks.enqueue(blank)
    end

    # A scan is not "no text", it is text we have not read yet — and the check
    # reads it. Refusing here made the member transcribe by hand what the job
    # was about to do anyway.
    test "accepts a scan with no text yet", %{user: user} do
      scan =
        insert(:job_reference,
          user: user,
          body: nil,
          document: "zeugnis.png",
          document_fingerprint: String.duplicate("a", 64),
          document_content_type: "image/png",
          document_moderation: "approved"
        )

      assert {:ok, check} = Checks.enqueue(scan)
      assert check.status == "pending"
    end
  end

  describe "reading a scan as part of the check" do
    setup %{user: user} do
      %{
        scan:
          insert(:job_reference,
            user: user,
            body: nil,
            document: "zeugnis.png",
            document_fingerprint: String.duplicate("a", 64),
            document_content_type: "image/png",
            document_moderation: "approved"
          )
      }
    end

    # With no file on disk the extraction cannot even start, which is a fact
    # about this document and must fail visibly rather than retry forever.
    test "a document whose file is gone counts against the cap", %{scan: scan} do
      {:ok, _check} = Checks.enqueue(scan)
      Checks.deliver_due(analyze: ok_analyzer())

      check = Checks.latest_for(scan)
      assert check.status == "pending"
      assert check.attempts == 1
      assert check.last_error =~ "no_body"
    end

    # The prompt reads German employment law. Offering it for a Swiss Zeugnis
    # would produce a confident answer about the wrong legal system.
    test "refuses a Zeugnis issued outside the covered countries", %{user: user} do
      swiss = insert(:job_reference, user: user, country: "CH")
      assert {:error, :unsupported_country} = Checks.enqueue(swiss)
    end

    test "refuses when the installation runs no check", %{reference: reference} do
      put_config(:reference_checks_enabled, false)
      assert {:error, :disabled} = Checks.enqueue(reference)
    end

    test "enforces the daily allowance per member", %{user: user} do
      put_config(:reference_checks_per_day, 2)

      for _n <- 1..2 do
        reference = insert(:job_reference, user: user)
        assert {:ok, _check} = Checks.enqueue(reference)
      end

      third = insert(:job_reference, user: user)
      assert {:error, :rate_limited} = Checks.enqueue(third)
    end

    # The allowance is a rolling window, so the refusal may not promise
    # "tomorrow": somebody who used their last slot at 23:00 is free again at
    # 23:00 the next day. `next_slot_at/1` is what the sentence reads, so both
    # come from the same window.
    test "says when the next slot opens, from the same window it counts", %{user: user} do
      put_config(:reference_checks_per_day, 1)

      {:ok, check} = Checks.enqueue(insert(:job_reference, user: user))

      opens_at = Checks.next_slot_at(user.id)

      assert %DateTime{} = opens_at
      assert DateTime.diff(opens_at, check.queued_at) == Checks.window_seconds()
    end

    test "no slot used, nothing to wait for", %{user: user} do
      assert Checks.next_slot_at(user.id) == nil
    end

    test "one member's allowance does not limit another's", %{user: user} do
      put_config(:reference_checks_per_day, 1)

      {:ok, _mine} = Checks.enqueue(insert(:job_reference, user: user))

      other = insert(:user)
      assert {:ok, _theirs} = Checks.enqueue(insert(:job_reference, user: other))
    end
  end

  # Everyone waiting shares one queue, so "two ahead of you" goes stale the
  # moment somebody *else's* check finishes — and that transition never touches
  # the waiting member's own topic. Hence a queue-wide one.
  describe "the queue topic" do
    test "announces a check leaving the waiting set", %{reference: reference} do
      Checks.subscribe_queue()

      {:ok, _check} = Checks.enqueue(reference)
      # Enqueueing puts one at the back and moves nobody, so it is silent.
      refute_receive :queue_changed, 100

      Checks.deliver_due(analyze: ok_analyzer())
      # Starting it is the departure everyone behind is waiting to hear about.
      assert_receive :queue_changed, 500
    end

    test "a member behind sees their position shrink", %{user: user} do
      mine = insert(:job_reference, user: user)

      {:ok, _ahead} = Checks.enqueue(insert(:job_reference, user: user))
      {:ok, waiting} = Checks.enqueue(mine)

      assert Checks.queue_position(waiting) == 1

      Checks.deliver_due(analyze: ok_analyzer(), limit: 1)

      assert Checks.queue_position(waiting) == 0
    end

    # A lost race changed nothing, so it must not announce anything — a panel
    # that recomputes on every stray message is a panel that queries forever.
    test "stays silent when the claim does not match", %{reference: reference} do
      {:ok, _check} = Checks.enqueue(reference)
      Checks.deliver_due(analyze: ok_analyzer())

      Checks.subscribe_queue()
      # Nothing is pending now, so a drain claims nothing.
      Checks.deliver_due(analyze: ok_analyzer())

      refute_receive :queue_changed, 100
    end
  end

  describe "queue_position/1" do
    test "counts only what is ahead", %{user: user} do
      {:ok, first} = Checks.enqueue(insert(:job_reference, user: user))
      {:ok, second} = Checks.enqueue(insert(:job_reference, user: user))
      {:ok, third} = Checks.enqueue(insert(:job_reference, user: user))

      assert Checks.queue_position(first) == 0
      assert Checks.queue_position(second) == 1
      assert Checks.queue_position(third) == 2
    end

    test "a running check is no longer waiting" do
      assert Checks.queue_position(%Check{status: "running"}) == nil
      assert Checks.queue_position(%Check{status: "done"}) == nil
    end
  end

  describe "a successful run" do
    test "stores the answer and what produced it", %{reference: reference} do
      {:ok, _check} = Checks.enqueue(reference)
      Checks.deliver_due(analyze: ok_analyzer())

      check = Checks.latest_for(reference)
      assert check.status == "done"
      assert check.result_markdown =~ "Note 4"
      assert check.model == "qwen3.6:27b"
      assert check.skill_version == "3.0.24"
      assert check.prompt_tokens == 35_559
      assert check.finished_at
      assert check.started_at
    end

    # The member watches the row travel; each step has to reach their topic or
    # the page sits on "waiting" until they reload.
    test "broadcasts every state change to the member", %{reference: reference, user: user} do
      Vutuv.Activity.subscribe(user.id)

      {:ok, _check} = Checks.enqueue(reference)
      assert_receive {:reference_check, %Check{status: "pending"}}

      Checks.deliver_due(analyze: ok_analyzer())
      assert_receive {:reference_check, %Check{status: "running"}}
      assert_receive {:reference_check, %Check{status: "done"}}
    end
  end

  describe "the stored grade" do
    defp run_with(reference, markdown) do
      {:ok, _check} = Checks.enqueue(reference)
      Checks.deliver_due(analyze: ok_analyzer(%{@result | markdown: markdown}))
      Checks.latest_for(reference)
    end

    test "the run settles the grade instead of leaving it to be re-read", %{
      reference: reference
    } do
      assert run_with(reference, "**Gesamtnote: 2 (Gut)**").grade_span == "2 (Gut)"
    end

    # The column is what every reader takes, so a later sharpening of the
    # parser cannot restate a grade beside a Zeugnis the member has already
    # sent to an employer.
    test "a stored grade wins over what the report would parse to now", %{reference: reference} do
      check = run_with(reference, "**Gesamtnote: 4 (mangelhaft)**")
      frozen = %{check | grade_span: "1 (Sehr Gut)"}

      assert Check.grade_span(frozen) == "1 (Sehr Gut)"
      assert Check.grade_band(frozen) == :good
    end

    # A check finished before the column existed still shows its grade.
    test "a row without one falls back to reading the report", %{reference: reference} do
      check = run_with(reference, "**Gesamtnote: 2 (Gut)**")

      assert Check.grade_span(%{check | grade_span: nil}) == "2 (Gut)"
    end

    test "an answer stating no grade stores none", %{reference: reference} do
      assert run_with(reference, "## Befund\n\nUnauffällig.").grade_span == nil
    end
  end

  # A machine read a document a member never made public. That belongs in the
  # account log beside the sign-ins, and it names the model rather than the
  # verdict: which model read your Zeugnis is worth keeping for a year, what
  # mark it gave is the Zeugnis's business and disappears with it.
  describe "the account log" do
    test "a finished review is recorded on the member's account", %{
      reference: reference,
      user: user
    } do
      {:ok, _check} = Checks.enqueue(reference)
      Checks.deliver_due(analyze: ok_analyzer())

      event =
        user
        |> Vutuv.AccountEvents.recent(20)
        |> Enum.find(&(&1.kind == "job_reference_reviewed"))

      assert event
      assert event.details["model"] == @result.model
      refute Map.has_key?(event.details, "grade")
    end

    # Nothing is mailed from here any more. Every kind reaches an inbox
    # through one path (`Vutuv.Activity.Digest`), so a finished review leaves a
    # notification and nothing else — see activity_digest_test.exs for what
    # happens to it afterwards.
    test "a finished review sends no mail of its own", %{reference: reference, user: user} do
      user |> Ecto.Changeset.change(email_confirmed?: true) |> Repo.update!()
      insert(:email, user: user)

      {:ok, _check} = Checks.enqueue(reference)
      Checks.deliver_due(analyze: ok_analyzer())

      refute_received {:email, _email}
    end

    test "a failed review records nothing", %{reference: reference, user: user} do
      {:ok, _check} = Checks.enqueue(reference)
      Checks.deliver_due(analyze: fn _body -> {:error, {:service, :econnrefused}} end)

      kinds = user |> Vutuv.AccountEvents.recent(20) |> Enum.map(& &1.kind)
      refute "job_reference_reviewed" in kinds
    end
  end

  # A check occupies the model for minutes and dies with the release that holds
  # it, so a blue/green deploy or a reboot leaves rows in `running` that nobody
  # is running. Recovery keys on the heartbeat's silence, never on how long the
  # run has taken, or an eleven-minute CPU run would be re-queued on top of
  # itself.
  describe "surviving a restart" do
    test "a check whose worker went away is re-queued", %{reference: reference} do
      {:ok, check} = Checks.enqueue(reference)
      strand(check, seconds_ago: 600)

      assert Checks.resume_stuck() == 1
      assert Checks.latest_for(reference).status == "pending"
    end

    test "a check claimed by an older release, with no stamp at all, is re-queued", %{
      reference: reference
    } do
      {:ok, check} = Checks.enqueue(reference)
      strand(check, seconds_ago: nil)

      assert Checks.resume_stuck() == 1
      assert Checks.latest_for(reference).status == "pending"
    end

    # The one that matters: a slow run must not be taken away from the worker
    # that is still inside it.
    test "a long run that is still beating is left alone", %{reference: reference} do
      {:ok, check} = Checks.enqueue(reference)
      strand(check, seconds_ago: 30)

      assert Checks.resume_stuck() == 0
      assert Checks.latest_for(reference).status == "running"
    end

    test "the member's page is told, so the hourglass goes back to waiting", %{
      reference: reference,
      user: user
    } do
      Vutuv.Activity.subscribe(user.id)
      {:ok, check} = Checks.enqueue(reference)
      strand(check, seconds_ago: 600)

      Checks.resume_stuck()

      assert_receive {:reference_check, %Check{status: "pending"}}
    end

    test "a finished check is never resurrected", %{reference: reference} do
      {:ok, _check} = Checks.enqueue(reference)
      Checks.deliver_due(analyze: ok_analyzer())

      assert Checks.resume_stuck() == 0
      assert Checks.latest_for(reference).status == "done"
    end

    # Puts a check into the state a killed worker leaves behind: running, with
    # a heartbeat that stopped `seconds_ago` (or was never written).
    defp strand(check, seconds_ago: seconds) do
      beat = seconds && DateTime.add(DateTime.utc_now(:second), -seconds, :second)

      from(c in Check, where: c.id == ^check.id)
      |> Repo.update_all(set: [status: "running", heartbeat_at: beat])
    end
  end

  describe "how long it takes" do
    test "no finished check, no estimate", %{reference: reference} do
      {:ok, check} = Checks.enqueue(reference)

      assert Checks.typical_duration_ms() == nil
      assert Checks.estimated_wait_ms(check) == nil
    end

    # The median, not the mean: the same document takes ~45 s on a warm GPU and
    # ~11 minutes on a cold CPU, and one such run must not double the number
    # every member is quoted.
    test "one slow run does not move the typical duration", %{user: user} do
      for ms <- [60_000, 62_000, 58_000, 61_000, 900_000], do: finished_check(user, ms)

      assert Checks.typical_duration_ms() == 61_000
    end

    test "the quote covers your own run plus the queue ahead of it", %{
      user: user,
      reference: reference
    } do
      finished_check(user, 60_000)

      # Alone in the queue: one run of 60s, plus the 20% margin.
      {:ok, alone} = Checks.enqueue(reference)
      assert Checks.estimated_wait_ms(alone) == 72_000

      # Two other members queue, then a third check joins behind them.
      for _ <- 1..2, do: Checks.enqueue(insert(:job_reference, user: insert(:user)))
      {:ok, last} = Checks.enqueue(insert(:job_reference, user: user))

      assert Checks.queue_position(last) == 3
      assert Checks.estimated_wait_ms(last) == 288_000
    end

    # The check the model is chewing on right now sits in nobody's queue
    # position, so counting only the queued ones quotes a member one whole run
    # too little — and only ever when the model is busy, which is exactly when
    # somebody is watching the number.
    test "a run already in flight is part of the wait", %{user: user, reference: reference} do
      finished_check(user, 60_000)

      running = insert(:job_reference, user: insert(:user))
      {:ok, in_flight} = Checks.enqueue(running)

      from(c in Check, where: c.id == ^in_flight.id)
      |> Repo.update_all(
        set: [
          status: "running",
          started_at: DateTime.utc_now(:second),
          heartbeat_at: DateTime.utc_now(:second)
        ]
      )

      {:ok, mine} = Checks.enqueue(reference)

      # Nothing is queued ahead of mine, but the model is busy for another
      # ~60s, so the quote is two runs rather than one.
      assert Checks.queue_position(mine) == 0
      assert Checks.estimated_wait_ms(mine) > 100_000
    end

    # A run past its typical duration is "about to finish", never a negative
    # number pulling the estimate below one run.
    test "an overdue run in flight does not shrink the wait", %{user: user, reference: reference} do
      finished_check(user, 60_000)

      overdue = insert(:job_reference, user: insert(:user))
      {:ok, in_flight} = Checks.enqueue(overdue)
      long_ago = DateTime.add(DateTime.utc_now(:second), -3_600, :second)

      from(c in Check, where: c.id == ^in_flight.id)
      |> Repo.update_all(
        set: [status: "running", started_at: long_ago, heartbeat_at: DateTime.utc_now(:second)]
      )

      {:ok, mine} = Checks.enqueue(reference)

      assert Checks.estimated_wait_ms(mine) == 72_000
    end

    defp finished_check(user, duration_ms) do
      reference = insert(:job_reference, user: user)

      Repo.insert!(%Check{
        job_reference_id: reference.id,
        user_id: user.id,
        status: "done",
        duration_ms: duration_ms,
        queued_at: DateTime.utc_now(:second)
      })
    end
  end

  describe "staleness" do
    test "a result matching the current text is current", %{reference: reference} do
      {:ok, _check} = Checks.enqueue(reference)
      Checks.deliver_due(analyze: ok_analyzer())

      assert Check.current_for?(Checks.latest_for(reference), reference)
    end

    # Editing the Zeugnis does not delete the reading, it dates it.
    test "editing the text makes the result stale rather than gone", %{reference: reference} do
      {:ok, _check} = Checks.enqueue(reference)
      Checks.deliver_due(analyze: ok_analyzer())
      check = Checks.latest_for(reference)

      edited = %{reference | body: "Wir waren mit seinen Leistungen stets sehr zufrieden."}

      refute Check.current_for?(check, edited)
      assert check.result_markdown =~ "Note 4"
    end

    # The fingerprint asks "is this the same text", not "are these the same
    # bytes". An HTML <textarea> submits its line breaks as CRLF, so every
    # save of the entry — a corrected title, the visibility tick, a CV link —
    # rewrites a body the member never touched and would date every review on
    # the page. Measured on the dev database: both stored results reported
    # themselves outdated, and both fingerprints matched the body exactly once
    # the carriage returns came off.
    test "a line-ending change alone does not date the result", %{user: user} do
      reference = insert(:job_reference, user: user, body: "Sehr geehrte Damen,\nzufrieden.\n")

      {:ok, _check} = Checks.enqueue(reference)
      Checks.deliver_due(analyze: ok_analyzer())
      check = Checks.latest_for(reference)

      resubmitted = %{reference | body: "Sehr geehrte Damen,\r\nzufrieden.\r\n"}

      assert Check.current_for?(check, resubmitted)
    end

    test "fingerprint/1 reads CRLF, CR and LF as the same text" do
      lf = Checks.fingerprint("eine Zeile\nzwei Zeilen\n")

      assert Checks.fingerprint("eine Zeile\r\nzwei Zeilen\r\n") == lf
      assert Checks.fingerprint("eine Zeile\rzwei Zeilen\r") == lf
      refute Checks.fingerprint("eine Zeile zwei Zeilen") == lf
    end
  end

  describe "errors" do
    # The model being down is not this Zeugnis's fault: retry, and do not
    # spend one of its three attempts.
    test "a service error goes back to pending without counting an attempt", %{
      reference: reference
    } do
      {:ok, _check} = Checks.enqueue(reference)
      Checks.deliver_due(analyze: fn _body -> {:error, {:service, :econnrefused}} end)

      check = Checks.latest_for(reference)
      assert check.status == "pending"
      assert check.attempts == 0
      assert check.next_attempt_at
      assert check.last_error =~ "econnrefused"
    end

    test "an analysis error counts an attempt", %{reference: reference} do
      {:ok, _check} = Checks.enqueue(reference)
      Checks.deliver_due(analyze: fn _body -> {:error, {:analysis, :prompt_truncated}} end)

      check = Checks.latest_for(reference)
      assert check.status == "pending"
      assert check.attempts == 1
    end

    # Retrying an unchanged misconfiguration forever would occupy the queue
    # and tell nobody, so it fails visibly instead.
    test "gives up after three analysis errors", %{reference: reference} do
      {:ok, _check} = Checks.enqueue(reference)
      failing = fn _body -> {:error, {:analysis, :prompt_truncated}} end

      for _attempt <- 1..3 do
        Repo.update_all(Check, set: [next_attempt_at: nil])
        Checks.deliver_due(analyze: failing)
      end

      check = Checks.latest_for(reference)
      assert check.status == "failed"
      assert check.attempts == 3
      assert check.finished_at
    end

    test "a crashing analysis is caught and retried, not propagated", %{reference: reference} do
      {:ok, _check} = Checks.enqueue(reference)
      Checks.deliver_due(analyze: fn _body -> raise "boom" end)

      check = Checks.latest_for(reference)
      assert check.status == "pending"
      assert check.attempts == 1
    end

    test "a deleted Zeugnis cancels its in-flight check", %{reference: reference} do
      {:ok, check} = Checks.enqueue(reference)
      Repo.delete!(reference)

      # The row cascades with its parent, so nothing is left to cancel — the
      # member's screen is gone too.
      assert Repo.get(Check, check.id) == nil
    end

    # The error label reaches log lines and an admin screen. The member's
    # document must never travel with it.
    test "the stored error carries no Zeugnis text", %{user: user} do
      secret = "Geheime Krankheitsgeschichte von Herrn Berger"
      reference = insert(:job_reference, user: user, body: secret)

      {:ok, _check} = Checks.enqueue(reference)
      Checks.deliver_due(analyze: fn _body -> {:error, {:analysis, :bad_response}} end)

      check = Checks.latest_for(reference)
      refute check.last_error =~ "Berger"
      refute check.last_error =~ "Krankheit"
    end
  end

  describe "resume_stuck/0" do
    # A restart or a deploy mid-inference must not leave a member watching a
    # spinner forever.
    test "re-queues a check a crash left running", %{reference: reference} do
      {:ok, check} = Checks.enqueue(reference)

      long_ago = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -7_200, :second)

      Repo.update_all(Check, set: [status: "running", updated_at: long_ago])

      assert Checks.resume_stuck() == 1
      assert Repo.get(Check, check.id).status == "pending"
    end

    # "Genuinely running" now means "somebody stamped its heartbeat recently",
    # not "it has not been running for very long": an eleven-minute CPU run is
    # normal, and a row left behind by a deploy looks exactly like a fast one
    # until you ask whether anybody is still there.
    test "leaves a genuinely running check alone", %{reference: reference} do
      {:ok, check} = Checks.enqueue(reference)

      Repo.update_all(Check,
        set: [status: "running", heartbeat_at: DateTime.utc_now(:second)]
      )

      assert Checks.resume_stuck() == 0
      assert Repo.get(Check, check.id).status == "running"
    end
  end
end
