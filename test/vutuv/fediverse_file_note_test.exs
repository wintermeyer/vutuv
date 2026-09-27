defmodule Vutuv.FediverseFileNoteTest do
  @moduledoc """
  A post's files federate (issue #2111): each one a `Document` with its media
  type, its name and the address the proxy hands it out at, beside the photos
  and the clip. Mastodon skips a type it does not display rather than drawing
  an empty frame, so the Document costs its readers nothing and hands every
  server that can show a file the one address that serves it.

  Not async: it points the global `:uploads_dir_prefix` at a tmp dir.
  """

  use Vutuv.DataCase, async: false

  import Vutuv.AttachmentHelpers, only: [settle!: 1]
  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.AttachmentFixtures, as: Fixtures
  alias Vutuv.Attachments
  alias Vutuv.Posts
  alias Vutuv.Repo
  alias VutuvWeb.Fediverse.Docs

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_file_note_#{System.unique_integer([:positive])}")
    src = Path.join(tmp, "src")
    File.mkdir_p!(src)
    put_config(:uploads_dir_prefix, tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    %{user: insert_activated_user(fediverse_followers?: true, admin?: true), src: src}
  end

  test "the Note carries the file as a Document", %{user: user, src: src} do
    {:ok, file} = Attachments.create_pending(user, Fixtures.plain_pdf(src), "Preisliste.pdf")
    file = settle!(file)

    {:ok, post} = Posts.create_post(user, %{body: "Die Liste", attachment_ids: [file.id]})
    note = post |> Repo.preload(Docs.note_preloads()) |> Docs.note(user)

    assert [attachment] = note["attachment"]
    assert attachment["type"] == "Document"
    assert attachment["mediaType"] == "application/pdf"
    assert attachment["name"] == "Preisliste.pdf"
    assert attachment["url"] == VutuvWeb.Endpoint.url() <> Attachments.file_url(file)
  end
end
