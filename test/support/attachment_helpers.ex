defmodule Vutuv.AttachmentHelpers do
  @moduledoc """
  Running a file's preview pipeline in a test, and proving that it finished
  (issues #2178, #2186, #2189).

  `Vutuv.Attachments.Pages.render/1` is synchronous, and a renderer that misses
  its deadline leaves nothing an assertion trips over: the row keeps
  `stage: "rendering"` for the retry and only the third strike logs. A file in
  that state has no preview page, is unreadable for its recipient, and answers
  the attachment proxy's uniform 404, which is also what a refusal, an outsider
  and an unknown token get. So a render that never happened is quietly green for
  whatever the test is named after.
  """

  import Ecto.Query, only: [from: 2]
  import ExUnit.Assertions

  alias Vutuv.Attachments
  alias Vutuv.Attachments.Attachment
  alias Vutuv.Attachments.Pages
  alias Vutuv.Images.Image
  alias Vutuv.Moderation.ImageScan
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Repo
  alias Vutuv.UUIDv7

  @doc """
  Renders `attachment`'s pages and hands back the row the pipeline settled,
  having asserted that it settled and that its page is there.

  Exactly one page: every fixture that reaches this is a one-page document or a
  single picture, so an empty list is a render that failed. `stage: "ready"`
  alone would not do, because the pipeline settles a file it has no renderer for
  at `ready` too, with no pages at all, which is the shape that reads as success.

  `Pages.release/1` clears the AI gate in the modules that switch
  `:moderate_images` on; its answer is not the claim, `settled?/1` is.
  """
  def settle!(%Attachment{} = attachment) do
    Pages.render(attachment)

    assert [page] = Pages.list(attachment)
    Pages.release(page.id)

    assert_settled(attachment)
  end

  @doc """
  The same claim for a module that asks for no pages at all
  (`preview_pages: 0`), where the pipeline settles the file itself.
  """
  def settled!(%Attachment{} = attachment) do
    Pages.render(attachment)
    assert_settled(attachment)
  end

  @doc """
  One preview page for `attachment`, in the state a verdict would leave it —
  written rather than rendered, so a test about the *wait* does not depend on
  poppler or Chromium being on the machine running the suite.
  """
  def page!(%Attachment{} = attachment, moderation) do
    now = NaiveDateTime.utc_now(:second)

    Repo.insert!(%Image{
      id: UUIDv7.generate(),
      kind: Pages.kind(),
      attachment_id: attachment.id,
      user_id: attachment.user_id,
      token: Vutuv.Uploads.gen_token(),
      position: 0,
      moderation: moderation,
      width: 1240,
      height: 1667,
      content_type: "image/avif",
      size_bytes: 1234,
      inserted_at: now,
      updated_at: now
    })
  end

  @doc """
  The queue row an unreachable Ollama leaves behind for one preview page: open,
  retrying, and failing against the **service** rather than against the picture
  — which is the distinction the stall ceiling is drawn on (issue #2149).

  `seconds` is how long that one outage has been running, written rather than
  waited for, so the gate is decided by the row and never by the time of day
  the suite runs at. Replaces any open scan on the page, so a test can age the
  same outage twice.
  """
  def stalled_scan!(%Image{} = page, seconds) do
    Repo.delete_all(
      from(s in ImageScan,
        where: s.subject_id == ^page.id and s.status in ^ImageScan.open_statuses()
      )
    )

    now = DateTime.utc_now(:second)

    Repo.insert!(%ImageScan{
      kind: Pages.kind(),
      subject_id: page.id,
      owner_user_id: page.user_id,
      status: "pending",
      next_attempt_at: DateTime.add(now, 300, :second),
      last_error: "econnrefused",
      service_failing_since: DateTime.add(now, -seconds, :second)
    })
  end

  @doc "How long an outage has to run before a waiting post stops claiming a check."
  def stall_after_seconds, do: ImageScans.stall_after_seconds()

  # The row is re-read rather than taken from `render/1`: that function writes
  # the stage and answers a struct saying so in one breath, so its return value
  # cannot corroborate itself.
  defp assert_settled(%Attachment{id: id}) do
    settled = Repo.get!(Attachment, id)
    assert Attachments.settled?(settled)
    settled
  end
end
