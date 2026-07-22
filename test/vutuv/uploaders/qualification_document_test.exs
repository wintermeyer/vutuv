defmodule Vutuv.QualificationDocumentTest do
  use Vutuv.DataCase, async: true

  alias Vix.Vips.MutableImage
  alias Vutuv.QualificationDocument
  alias Vutuv.UUIDv7

  @pdf_fixture Path.expand("../../support/fixtures/certificate.pdf", __DIR__)

  defp jpeg_upload do
    src = Path.join(System.tmp_dir!(), "qdoc_#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(600, 400, color: [10, 120, 200])

    {:ok, tagged} =
      Image.mutate(img, fn mut ->
        :ok = MutableImage.set(mut, "exif-ifd0-Make", :gchararray, "TestCam")
      end)

    {:ok, _} = Image.write(tagged, src)
    on_exit(fn -> File.rm(src) end)
    %Plug.Upload{filename: "scan.jpg", path: src, content_type: "image/jpeg"}
  end

  defp pdf_upload do
    %Plug.Upload{
      filename: "Gesellenbrief.pdf",
      path: @pdf_fixture,
      content_type: "application/pdf"
    }
  end

  defp store!(upload) do
    id = UUIDv7.generate()
    on_exit(fn -> QualificationDocument.delete(id) end)
    {:ok, meta} = QualificationDocument.store(upload, id)
    {id, meta}
  end

  describe "validate/1" do
    test "accepts a JPEG" do
      assert :ok = QualificationDocument.validate(jpeg_upload())
    end

    test "rejects an unknown extension" do
      upload = %Plug.Upload{filename: "cert.docx", path: @pdf_fixture}
      assert {:error, :invalid_file} = QualificationDocument.validate(upload)
    end

    test "rejects an oversized file" do
      src = Path.join(System.tmp_dir!(), "big_#{System.unique_integer([:positive])}.jpg")
      File.write!(src, :binary.copy(<<0>>, QualificationDocument.max_size() + 1))
      on_exit(fn -> File.rm(src) end)

      upload = %Plug.Upload{filename: "big.jpg", path: src}
      assert {:error, :too_large} = QualificationDocument.validate(upload)
    end

    test "rejects bytes that are not really an image" do
      src = Path.join(System.tmp_dir!(), "fake_#{System.unique_integer([:positive])}.jpg")
      File.write!(src, "not an image at all")
      on_exit(fn -> File.rm(src) end)

      upload = %Plug.Upload{filename: "fake.jpg", path: src}
      assert {:error, :invalid_file} = QualificationDocument.validate(upload)
    end
  end

  describe "storing an image" do
    test "writes the thumb, a metadata-stripped public copy and the private original" do
      {id, meta} = store!(jpeg_upload())

      assert meta.content_type == "image/jpeg"
      assert meta.size > 0
      assert String.length(meta.fingerprint) == 12

      thumb = QualificationDocument.thumb_path(id)
      assert thumb && File.exists?(thumb)
      assert Path.extname(thumb) == ".avif"

      file = QualificationDocument.file_path(id)
      assert file && File.exists?(file)
      assert Path.extname(file) == ".jpg"

      # The public copy must not leak the original's EXIF.
      {:ok, public} = Image.open(file)

      case Image.exif(public) do
        {:ok, exif} -> refute get_in(exif, [:image, :make]) || exif[:make]
        {:error, _} -> :ok
      end

      # The verbatim original stays in the private tree — the moderation source.
      assert source = QualificationDocument.scan_source_path(id)
      assert File.exists?(source)
    end
  end

  describe "storing a PDF" do
    @describetag :pdf

    test "renders page 1 into the thumb and keeps the PDF verbatim" do
      if QualificationDocument.pdf_supported?() do
        {id, meta} = store!(pdf_upload())

        assert meta.content_type == "application/pdf"

        thumb = QualificationDocument.thumb_path(id)
        assert thumb && File.exists?(thumb)

        file = QualificationDocument.file_path(id)
        assert Path.extname(file) == ".pdf"
        assert File.read!(file) == File.read!(@pdf_fixture)

        # The moderation source is the rendered first page, not the PDF itself
        # (the vision model cannot decode a PDF).
        source = QualificationDocument.scan_source_path(id)
        assert Path.extname(source) == ".jpg"
      else
        # Without poppler-utils the PDF is rejected up front with its own
        # error, so the member gets a clear message instead of a broken upload.
        assert {:error, :pdf_unsupported} = QualificationDocument.validate(pdf_upload())
      end
    end
  end

  test "delete/1 removes every stored file" do
    {id, _meta} = store!(jpeg_upload())
    assert QualificationDocument.thumb_path(id)

    :ok = QualificationDocument.delete(id)

    refute QualificationDocument.thumb_path(id)
    refute QualificationDocument.file_path(id)
    refute QualificationDocument.scan_source_path(id)
  end

  test "a re-upload replaces the stored files" do
    {id, first} = store!(jpeg_upload())
    {:ok, second} = QualificationDocument.store(pdf_or_second_image(), id)

    refute first.fingerprint == second.fingerprint
    # Exactly one public copy remains.
    assert QualificationDocument.file_path(id)
  end

  defp pdf_or_second_image do
    if QualificationDocument.pdf_supported?() do
      pdf_upload()
    else
      src = Path.join(System.tmp_dir!(), "qdoc2_#{System.unique_integer([:positive])}.png")
      {:ok, img} = Image.new(300, 300, color: [200, 30, 30])
      {:ok, _} = Image.write(img, src)
      on_exit(fn -> File.rm(src) end)
      %Plug.Upload{filename: "scan2.png", path: src, content_type: "image/png"}
    end
  end
end
