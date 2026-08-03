defmodule Vutuv.References.DocumentModerationTest do
  @moduledoc """
  How an uploaded Arbeitszeugnis travels through the AI image moderation, and
  what a rejection is allowed to take with it.

  The load-bearing claim here is that a rejection clears the *file* and leaves
  the member's text alone. The model judged a picture; the Zeugnis text is
  something the member typed or proof-read, and destroying it on the strength
  of a verdict that never covered it would be a data loss they cannot undo.
  """
  use Vutuv.DataCase, async: true

  import Vutuv.Factory

  alias Vutuv.Moderation.ImageScan
  alias Vutuv.Moderation.ImageSubjects
  alias Vutuv.References.JobReference
  alias Vutuv.Repo

  @fingerprint String.duplicate("f", 64)

  defp with_document(user, attrs \\ []) do
    insert(
      :job_reference,
      Keyword.merge(
        [
          user: user,
          body: "Wir waren mit seinen Leistungen zufrieden.",
          document: "zeugnis.pdf",
          document_fingerprint: @fingerprint,
          document_content_type: "application/pdf",
          document_size: 12_345,
          document_moderation: "pending"
        ],
        attrs
      )
    )
  end

  defp scan_for(reference, fingerprint \\ @fingerprint) do
    insert(:image_scan,
      kind: "job_reference_document",
      subject_id: reference.id,
      owner_user_id: reference.user_id,
      fingerprint: fingerprint,
      status: "scanning"
    )
  end

  setup do
    %{user: insert(:user)}
  end

  test "the kind is one the scan queue accepts" do
    assert "job_reference_document" in ImageScan.kinds()
  end

  describe "approval" do
    test "releases the document", %{user: user} do
      reference = with_document(user)

      assert :ok = ImageSubjects.apply_approved(scan_for(reference))
      assert Repo.get(JobReference, reference.id).document_moderation == "approved"
    end

    # A verdict on bytes that have since been replaced must not release the
    # replacement, which nothing has looked at.
    test "a verdict on replaced bytes is stale, not a release", %{user: user} do
      reference = with_document(user)

      assert :stale = ImageSubjects.apply_approved(scan_for(reference, "different"))
      assert Repo.get(JobReference, reference.id).document_moderation == "pending"
    end
  end

  describe "rejection" do
    test "clears every document column", %{user: user} do
      reference = with_document(user)

      assert :ok = ImageSubjects.apply_rejected(scan_for(reference))

      reloaded = Repo.get(JobReference, reference.id)
      assert is_nil(reloaded.document)
      assert is_nil(reloaded.document_fingerprint)
      assert is_nil(reloaded.document_content_type)
      assert is_nil(reloaded.document_size)
      assert is_nil(reloaded.document_moderation)
    end

    # The point of the whole test module.
    test "keeps the entry and the member's text", %{user: user} do
      reference = with_document(user)

      assert :ok = ImageSubjects.apply_rejected(scan_for(reference))

      reloaded = Repo.get(JobReference, reference.id)
      assert reloaded
      assert reloaded.body == "Wir waren mit seinen Leistungen zufrieden."
      assert reloaded.title == reference.title
    end

    test "a verdict on replaced bytes changes nothing", %{user: user} do
      reference = with_document(user)

      assert :stale = ImageSubjects.apply_rejected(scan_for(reference, "different"))
      assert Repo.get(JobReference, reference.id).document == "zeugnis.pdf"
    end
  end

  describe "drift repair" do
    # A crash between the upload and the enqueue would otherwise leave a
    # document in owner-only limbo forever, with nothing scheduled to free it.
    test "finds a pending document with no open scan", %{user: user} do
      reference = with_document(user)

      stranded = ImageSubjects.stranded_pending()

      assert {"job_reference_document", reference.id, user.id, @fingerprint} in stranded
    end

    test "ignores one that already has an open scan", %{user: user} do
      reference = with_document(user)
      scan_for(reference)

      refute Enum.any?(ImageSubjects.stranded_pending(), fn {kind, id, _owner, _fp} ->
               kind == "job_reference_document" and id == reference.id
             end)
    end

    test "ignores an already-approved document", %{user: user} do
      reference = with_document(user, document_moderation: "approved")

      refute Enum.any?(ImageSubjects.stranded_pending(), fn {kind, id, _owner, _fp} ->
               kind == "job_reference_document" and id == reference.id
             end)
    end
  end

  describe "the reset field list" do
    # One shared list, so no clearing path (owner removal, store failure,
    # moderation rejection) can forget a column.
    test "names every document column on the schema" do
      reset = Keyword.keys(JobReference.document_reset_fields())

      for field <- ~w(document document_fingerprint document_content_type
                      document_size document_moderation document_page_count)a do
        assert field in reset, "#{field} is missing from document_reset_fields/0"
      end
    end
  end
end
