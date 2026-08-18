defmodule Vutuv.Translations.PriorityTest do
  @moduledoc """
  A reader never queues behind the background sweep.

  Three separate mechanisms carry that, and each is asserted here: the drain
  order, the promotion of a job the sweep had already opened, and the
  one-job-per-query drain that lets a request landing mid-batch be picked up
  next rather than after the whole batch this round started with.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Translations
  alias Vutuv.Translations.TranslationJob

  @background TranslationJob.background_priority()
  @reader TranslationJob.reader_priority()

  defp german_post(body), do: insert(:post, body: body, language: "de")

  # FIFO within a priority is settled by `inserted_at` (whole seconds) and then
  # by the id, and a test writes every row inside one second. So the tests that
  # claim priority BEAT age have to give age something to say: backdate the job
  # that must lose, and it wins on every tiebreaker the queue has.
  defp queued_an_hour_ago(post, priority) do
    {:queued, job} = Translations.queue(post, "en", priority)
    an_hour_ago = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -3600, :second)

    Repo.update_all(from(j in TranslationJob, where: j.id == ^job.id),
      set: [inserted_at: an_hour_ago]
    )

    job
  end

  defp translated_bodies do
    fn subject, _target ->
      {:ok, %{source_language: "de", body: "EN: " <> subject.body, summary: nil, model: "stub"}}
    end
  end

  test "a reader's job drains before background work queued long before it" do
    old = german_post("Der alte Beitrag.")
    queued_an_hour_ago(old, @background)

    fresh = german_post("Was der Leser wissen will.")
    {:queued, _} = Translations.request(fresh, "en")

    assert [%TranslationJob{post_id: first}] = Translations.list_due(limit: 1)
    assert first == fresh.id, "an hour of seniority must not outrank somebody waiting"
  end

  test "a reader joins the sweep's open job instead of opening a second one" do
    post = german_post("Guten Morgen.")
    {:queued, background} = Translations.queue(post, "en", @background)
    assert background.priority == @background

    {:queued, promoted} = Translations.request(post, "en")

    assert promoted.id == background.id, "the reader must land on the running job, not a copy"
    assert promoted.priority == @reader
    assert Repo.aggregate(from(j in TranslationJob, where: j.post_id == ^post.id), :count) == 1
  end

  test "the sweep never demotes a job a reader is waiting for" do
    post = german_post("Guten Morgen.")
    {:queued, readers} = Translations.request(post, "en")

    {:queued, same} = Translations.queue(post, "en", @background)

    assert same.id == readers.id
    assert Repo.reload!(readers).priority == @reader
  end

  test "a running job is left alone: it is already as fast as it gets" do
    post = german_post("Guten Morgen.")
    {:queued, job} = Translations.queue(post, "en", @background)
    Repo.update_all(from(j in TranslationJob, where: j.id == ^job.id), set: [status: "running"])

    {:queued, still_running} = Translations.request(post, "en")

    assert still_running.id == job.id
    assert Repo.reload!(job).status == "running"
  end

  test "a deploy mid-translation gives the job back at the rank it had" do
    post = german_post("Guten Morgen.")
    {:queued, job} = Translations.queue(post, "en", @background)
    {:queued, promoted} = Translations.request(post, "en")
    assert promoted.id == job.id

    # What a release being killed mid-call leaves behind: a claim nobody is
    # holding any more. `resume_stuck/0` runs on the next boot.
    long_ago = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -3600, :second)

    Repo.update_all(from(j in TranslationJob, where: j.id == ^job.id),
      set: [status: "running", updated_at: long_ago]
    )

    assert Translations.resume_stuck() == 1

    resumed = Repo.reload!(job)
    assert resumed.status == "pending"
    assert resumed.priority == @reader, "the reader must not lose their place to a deploy"
  end

  test "max_priority stands the sweep down without touching reader work" do
    background_post = german_post("Der Hintergrund.")
    {:queued, _} = Translations.queue(background_post, "en", @background)
    reader_post = german_post("Der Leser.")
    {:queued, _} = Translations.request(reader_post, "en")

    :ok = Translations.deliver_due(max_priority: @reader, translate: translated_bodies())

    assert Translations.fresh_translation(reader_post, "en").body == "EN: Der Leser."
    assert Translations.fresh_translation(background_post, "en") == nil
    # Still queued, not failed: the box was busy, the row is fine.
    assert [%TranslationJob{}] = Translations.list_due(limit: 5)
  end

  test "a request landing mid-drain is served next, not after the batch" do
    latecomer = german_post("Der Nachzügler.")

    first = german_post("Der Erste.")
    queued_an_hour_ago(first, @background)
    second = german_post("Der Zweite.")
    queued_an_hour_ago(second, @background)

    # The reader taps while the first background job is in the model. A drain
    # that selected its whole batch up front would finish `second` before ever
    # looking at this row.
    interrupting = fn subject, target ->
      if subject.id == first.id, do: {:queued, _} = Translations.request(latecomer, "en")
      {:ok, %{source_language: "de", body: "EN: " <> subject.body, summary: nil, model: target}}
    end

    :ok = Translations.deliver_due(limit: 2, translate: interrupting)

    assert Translations.fresh_translation(latecomer, "en"),
           "the reader's request must be picked up by the next iteration"

    assert Translations.fresh_translation(second, "en") == nil
  end
end
