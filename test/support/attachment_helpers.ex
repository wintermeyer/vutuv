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

  import ExUnit.Assertions

  alias Vutuv.Attachments
  alias Vutuv.Attachments.Attachment
  alias Vutuv.Attachments.Pages
  alias Vutuv.Repo

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

  # The row is re-read rather than taken from `render/1`: that function writes
  # the stage and answers a struct saying so in one breath, so its return value
  # cannot corroborate itself.
  defp assert_settled(%Attachment{id: id}) do
    settled = Repo.get!(Attachment, id)
    assert Attachments.settled?(settled)
    settled
  end
end
