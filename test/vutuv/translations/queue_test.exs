defmodule Vutuv.Translations.QueueTest do
  @moduledoc """
  The translation job queue (issue #1458), drained via
  `Translations.deliver_due/1` with a stubbed translator (the worker itself
  stays off in tests — sandbox rule). The load-bearing assertions: EVERY
  outcome stamps the job, including the do-nothing branches — an unstamped
  skip would hold the front of the oldest-first batch forever (the
  `refresh_counts` starvation lesson).
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Translations
  alias Vutuv.Translations.Translation
  alias Vutuv.Translations.TranslationJob

  defp queued_job!(post, target \\ "en") do
    {:queued, job} = Translations.request(post, target)
    job
  end

  defp ok_translator(body \\ "Translated.") do
    fn _subject, _target ->
      {:ok, %{source_language: "de", body: body, summary: nil, model: "stub"}}
    end
  end

  defp failing_translator(error) do
    fn _subject, _target -> {:error, error} end
  end

  test "a due job translates, stores, completes and broadcasts" do
    post = insert(:post, body: "Guten Morgen.")
    job = queued_job!(post)
    Phoenix.PubSub.subscribe(Vutuv.PubSub, Translations.topic(post))

    :ok = Translations.deliver_due(translate: ok_translator("Good morning."))

    assert Repo.reload!(job).status == "done"
    assert %Translation{body: "Good morning."} = Translations.fresh_translation(post, "en")
    assert_receive {:translation_ready, %Translation{body: "Good morning."}}
    assert Translations.list_due() == []
  end

  test "an already-stored fresh translation completes the job WITHOUT a model call" do
    post = insert(:post, body: "Guten Morgen.")
    job = queued_job!(post)

    {:ok, _} = Translations.store_translation(post, "en", %{body: "Good morning.", model: "m"})

    exploding = fn _subject, _target -> raise "the skip branch must not translate" end
    :ok = Translations.deliver_due(translate: exploding)

    # The skip is stamped: the job left the due query instead of holding the
    # front of the batch forever (the refresh_counts starvation lesson —
    # calibrated against the un-fixed shape, where this stays "pending").
    assert Repo.reload!(job).status == "done"
    assert Translations.list_due() == []
  end

  test "a service failure retries patiently and is not due immediately" do
    post = insert(:post, body: "Guten Morgen.")
    job = queued_job!(post)

    :ok = Translations.deliver_due(translate: failing_translator({:service, :econnrefused}))

    reloaded = Repo.reload!(job)
    assert reloaded.status == "pending"
    assert reloaded.attempts == 1
    assert reloaded.last_error =~ "econnrefused"
    assert DateTime.after?(reloaded.next_attempt_at, DateTime.utc_now())
    assert Translations.list_due() == []
  end

  test "content strikes back off, and the cap ends the job failed with a broadcast" do
    post = insert(:post, body: "Guten Morgen.")
    job = queued_job!(post)
    Phoenix.PubSub.subscribe(Vutuv.PubSub, Translations.topic(post))

    for _round <- 1..4 do
      Repo.update_all(TranslationJob, set: [next_attempt_at: nil])
      :ok = Translations.deliver_due(translate: failing_translator({:content, :length_ratio}))
    end

    reloaded = Repo.reload!(job)
    assert reloaded.status == "failed"
    assert reloaded.attempts == 4
    assert_receive {:translation_failed, {:post, _id}, "en"}
    assert Translations.list_due() == []

    # The failed row does not block a deliberate later request.
    assert {:queued, %TranslationJob{status: "pending"}} = Translations.request(post, "en")
  end

  test "resume_stuck re-queues a job a crash left running" do
    post = insert(:post, body: "Guten Morgen.")
    job = queued_job!(post)

    long_ago = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -7200, :second)
    Repo.update_all(TranslationJob, set: [status: "running", updated_at: long_ago])

    assert Translations.resume_stuck() == 1
    assert Repo.reload!(job).status == "pending"

    # A freshly claimed job is NOT presumed crashed.
    Repo.update_all(TranslationJob, set: [status: "running"])
    assert Translations.resume_stuck() == 0
  end

  test "a stale cached translation is refreshed in place by the next job" do
    post = insert(:post, body: "Guten Morgen.")
    {:ok, stale} = Translations.store_translation(post, "en", %{body: "Old.", model: "m"})

    edited = post |> Ecto.Changeset.change(%{body: "Guten Abend."}) |> Repo.update!()
    _job = queued_job!(edited)

    :ok = Translations.deliver_due(translate: ok_translator("Good evening."))

    assert Repo.aggregate(Translation, :count) == 1
    assert Repo.get!(Translation, stale.id).body == "Good evening."
  end
end
