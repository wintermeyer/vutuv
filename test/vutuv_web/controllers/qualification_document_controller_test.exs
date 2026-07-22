defmodule VutuvWeb.QualificationDocumentControllerTest do
  @moduledoc """
  End-to-end coverage of the qualification proof documents: the consent-gated
  upload, the moderation limbo (owner-only until the scan releases) and the
  authorizing document proxy.

  async: false — several tests flip the global `:moderate_images` app env,
  which every uploader in the VM reads.
  """
  use VutuvWeb.ConnCase, async: false

  alias Vutuv.Moderation.ImageScan
  alias Vutuv.Moderation.ImageSubjects
  alias Vutuv.Profiles.Qualification
  alias Vutuv.QualificationDocument

  @pdf_fixture Path.expand("../../support/fixtures/certificate.pdf", __DIR__)

  defp jpeg_upload do
    src = Path.join(System.tmp_dir!(), "qdc_#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(600, 400, color: [10, 120, 200])
    {:ok, _} = Image.write(img, src)
    on_exit(fn -> File.rm(src) end)
    %Plug.Upload{filename: "zertifikat.jpg", path: src, content_type: "image/jpeg"}
  end

  defp create_with_document(conn, upload, extra \\ %{}) do
    post(conn, ~p"/settings/qualifications", %{
      "qualification" =>
        Map.merge(
          %{
            "name" => "Meisterbrief",
            "kind" => "certification",
            "document" => upload,
            "document_consent" => "true"
          },
          extra
        )
    })
  end

  defp owner_qualification(user) do
    q = Repo.get_by!(Qualification, user_id: user.id)
    on_exit(fn -> QualificationDocument.delete(q.id) end)
    q
  end

  test "uploading with consent stores the document and serves it", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    conn2 = create_with_document(conn, jpeg_upload())
    assert redirected_to(conn2) == ~p"/settings/qualifications"

    q = owner_qualification(user)
    assert q.document == "zertifikat.jpg"
    assert q.document_content_type == "image/jpeg"
    assert %DateTime{} = q.document_consented_at
    # Moderation is off here, so the document starts released.
    assert q.document_moderation == "approved"
    assert QualificationDocument.thumb_path(q.id)

    # The thumbnail renders on the public index and on the editor.
    html = build_conn() |> get(~p"/#{user}/qualifications") |> html_response(200)
    assert html =~ "data-document-thumb"

    # The document itself: inline by default, attachment via ?dl=1, and the
    # save-as name is the member's original filename.
    doc_conn =
      get(
        build_conn(),
        "/#{user.username}/qualifications/#{q.id}/document/#{q.document_fingerprint}.jpg"
      )

    assert doc_conn.status == 200
    assert get_resp_header(doc_conn, "content-type") |> hd() =~ "image/jpeg"
    assert get_resp_header(doc_conn, "content-disposition") |> hd() =~ "inline"
    assert get_resp_header(doc_conn, "content-disposition") |> hd() =~ "zertifikat.jpg"

    dl_conn =
      get(
        build_conn(),
        "/#{user.username}/qualifications/#{q.id}/document/#{q.document_fingerprint}.jpg?dl=1"
      )

    assert get_resp_header(dl_conn, "content-disposition") |> hd() =~ "attachment"

    thumb_conn =
      get(
        build_conn(),
        "/#{user.username}/qualifications/#{q.id}/document/thumb-#{q.document_fingerprint}.avif"
      )

    assert thumb_conn.status == 200
    assert get_resp_header(thumb_conn, "content-type") |> hd() =~ "image/avif"

    # A stale fingerprint must 404 (immutable-cache safety).
    assert build_conn()
           |> get("/#{user.username}/qualifications/#{q.id}/document/aaaaaaaaaaaa.jpg")
           |> Map.get(:status) == 404
  end

  test "without consent nothing is stored", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    conn2 =
      post(conn, ~p"/settings/qualifications", %{
        "qualification" => %{
          "name" => "Meisterbrief",
          "kind" => "certification",
          "document" => jpeg_upload()
        }
      })

    assert html_response(conn2, 422)
    assert Repo.get_by(Qualification, user_id: user.id) == nil
  end

  test "a pending document is owner-only until the scan releases it", %{conn: conn} do
    Application.put_env(:vutuv, :moderate_images, true)
    on_exit(fn -> Application.put_env(:vutuv, :moderate_images, false) end)

    {conn, user} = create_and_login_user(conn)
    create_with_document(conn, jpeg_upload())
    q = owner_qualification(user)

    assert q.document_moderation == "pending"
    # The scan was enqueued, bound to these bytes.
    scan = Repo.get_by!(ImageScan, kind: "qualification_document", subject_id: q.id)
    assert scan.fingerprint == q.document_fingerprint
    assert scan.owner_user_id == user.id

    doc_path = "/#{user.username}/qualifications/#{q.id}/document/#{q.document_fingerprint}.jpg"

    # Visitors: no thumbnail rendered, proxy 404s.
    visitor_html = build_conn() |> get(~p"/#{user}/qualifications") |> html_response(200)
    refute visitor_html =~ "data-document-thumb"
    assert build_conn() |> get(doc_path) |> Map.get(:status) == 404

    # The owner previews it, marked as being reviewed.
    owner_html = conn |> get(~p"/settings/qualifications") |> html_response(200)
    assert owner_html =~ "data-document-thumb"
    assert owner_html =~ "data-document-pending"
    assert conn |> get(doc_path) |> Map.get(:status) == 200

    # The verdict releases it for everyone.
    assert :ok = ImageSubjects.apply_approved(scan)
    assert Repo.get!(Qualification, q.id).document_moderation == "approved"
    assert build_conn() |> get(doc_path) |> Map.get(:status) == 200
  end

  test "a rejection deletes the files and clears the columns", %{conn: conn} do
    Application.put_env(:vutuv, :moderate_images, true)
    on_exit(fn -> Application.put_env(:vutuv, :moderate_images, false) end)

    {conn, user} = create_and_login_user(conn)
    create_with_document(conn, jpeg_upload())
    q = owner_qualification(user)
    scan = Repo.get_by!(ImageScan, kind: "qualification_document", subject_id: q.id)

    assert :ok = ImageSubjects.apply_rejected(scan)

    reloaded = Repo.get!(Qualification, q.id)
    assert reloaded.document == nil
    assert reloaded.document_fingerprint == nil
    refute QualificationDocument.thumb_path(q.id)
  end

  test "the owner can remove the document without deleting the entry", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    create_with_document(conn, jpeg_upload())
    q = owner_qualification(user)

    conn2 = delete(conn, ~p"/settings/qualifications/#{q}/document")
    assert redirected_to(conn2) == ~p"/settings/qualifications"

    reloaded = Repo.get!(Qualification, q.id)
    assert reloaded.document == nil
    assert reloaded.name == "Meisterbrief"
    refute QualificationDocument.thumb_path(q.id)
  end

  test "deleting the qualification removes the stored files", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    create_with_document(conn, jpeg_upload())
    q = owner_qualification(user)
    assert QualificationDocument.thumb_path(q.id)

    delete(conn, ~p"/settings/qualifications/#{q}")

    refute Repo.get(Qualification, q.id)
    refute QualificationDocument.thumb_path(q.id)
  end

  test "a foreign member cannot remove someone else's document", %{conn: conn} do
    {owner_conn, owner} = create_and_login_user(conn)
    create_with_document(owner_conn, jpeg_upload())
    q = owner_qualification(owner)

    {other_conn, _other} =
      create_and_login_user(Plug.Test.init_test_session(build_conn(), %{}))

    assert other_conn |> delete(~p"/settings/qualifications/#{q}/document") |> Map.get(:status) ==
             404

    assert Repo.get!(Qualification, q.id).document
  end

  test "the entry page offers the download with the size label", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    create_with_document(conn, jpeg_upload())
    q = owner_qualification(user)

    html = build_conn() |> get(~p"/#{user}/qualifications/#{q}") |> html_response(200)
    assert html =~ "data-document-thumb"
    assert html =~ "data-document-download"

    # The agent-doc sibling carries the document facts.
    json =
      build_conn()
      |> get("/#{user.username}/qualifications/#{q.id}.json")
      |> Map.get(:resp_body)
      |> Jason.decode!()

    assert json["entry"]["document"]["content_type"] == "image/jpeg"
    assert json["entry"]["document"]["url"] =~ "/document/#{q.document_fingerprint}.jpg"
  end

  test "a PDF becomes a page-1 thumbnail and downloads verbatim", %{conn: conn} do
    if QualificationDocument.pdf_supported?() do
      {conn, user} = create_and_login_user(conn)

      upload = %Plug.Upload{
        filename: "Gesellenbrief.pdf",
        path: @pdf_fixture,
        content_type: "application/pdf"
      }

      create_with_document(conn, upload)
      q = owner_qualification(user)

      assert q.document_content_type == "application/pdf"

      thumb_conn =
        get(
          build_conn(),
          "/#{user.username}/qualifications/#{q.id}/document/thumb-#{q.document_fingerprint}.avif"
        )

      assert thumb_conn.status == 200

      doc_conn =
        get(
          build_conn(),
          "/#{user.username}/qualifications/#{q.id}/document/#{q.document_fingerprint}.pdf"
        )

      assert doc_conn.status == 200
      assert get_resp_header(doc_conn, "content-type") |> hd() =~ "application/pdf"
      assert doc_conn.resp_body == File.read!(@pdf_fixture)
    else
      :ok
    end
  end
end
