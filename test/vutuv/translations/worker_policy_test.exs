defmodule Vutuv.Translations.WorkerPolicyTest do
  @moduledoc """
  The two decisions the translation worker's poll makes before it does any
  work, tested without running the worker (it stays off in tests — sandbox
  rule).

  Both are gates on work nobody is waiting for, and both have a failure mode
  that is silent: a queue that keeps a standing background backlog answers
  "is anything queued" yes forever, so a gate asking that question switches
  its sweep off permanently instead of merely delaying it.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Translations
  alias Vutuv.Translations.TranslationJob
  alias Vutuv.Translations.Worker

  defp german_post, do: insert(:post, body: "Guten Morgen.", language: "de")

  describe "reader_waiting?/0" do
    test "a standing background backlog does not read as somebody waiting" do
      for n <- 1..3 do
        post = insert(:post, body: "Beitrag #{n}.", language: "de")
        {:queued, _} = Translations.queue(post, "en", TranslationJob.background_priority())
      end

      # The un-fixed shape asked whether the queue was EMPTY, which these three
      # rows answer no to for as long as the sweep keeps them topped up — and
      # language detection, the thing that decides which posts can ever be
      # pre-translated, sits behind this gate.
      refute Translations.reader_waiting?()
    end

    test "a reader's request does" do
      {:queued, _} = Translations.request(german_post(), "en")

      assert Translations.reader_waiting?()
    end

    test "a job that is not due yet is nobody waiting" do
      {:queued, job} = Translations.request(german_post(), "en")
      later = DateTime.add(DateTime.utc_now(:second), 300, :second)

      Repo.update_all(from(j in TranslationJob, where: j.id == ^job.id),
        set: [next_attempt_at: later]
      )

      refute Translations.reader_waiting?()
    end
  end

  describe "drain_priority/0" do
    test "an open image scan stands the background sweep down" do
      assert Worker.drain_priority() == TranslationJob.background_priority()

      # The row directly, not `ImageScans.enqueue/4`: image moderation is off
      # in the test env, and turning it on here would turn it on for every
      # async test running beside this one.
      insert(:image_scan, kind: "post_image", subject_id: Vutuv.UUIDv7.generate())

      assert ImageScans.busy?()
      assert Worker.drain_priority() == TranslationJob.reader_priority()
    end
  end
end
