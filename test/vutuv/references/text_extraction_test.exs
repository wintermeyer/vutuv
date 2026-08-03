defmodule Vutuv.References.TextExtractionTest do
  @moduledoc """
  The extraction ladder. `image_only?/2` — the rung selector — is pure and
  gets the close attention here, because everything below it depends on that
  one judgement being right: call a text PDF a scan and a perfectly readable
  document goes through OCR, call a scan a text PDF and the analysis reads an
  empty string.

  The rungs themselves are capability-gated, so the tests that need poppler
  skip cleanly on a host without it rather than failing.
  """
  use ExUnit.Case, async: false

  alias Vutuv.References.JobReference
  alias Vutuv.References.TextExtraction

  @pdf_fixture Path.expand("../../support/fixtures/certificate.pdf", __DIR__)

  describe "image_only?/2" do
    test "a page of prose is not a scan" do
      page = String.duplicate("Wir waren mit seinen Leistungen zufrieden. ", 40)
      refute TextExtraction.image_only?(page, 1)
    end

    test "an empty result is a scan" do
      assert TextExtraction.image_only?("", 1)
      assert TextExtraction.image_only?("\f", 1)
      assert TextExtraction.image_only?("   \n\n  \f  ", 3)
    end

    # A scanned PDF often carries a few stray characters from a text-layer
    # header or a stamp. That must not read as "this PDF has text".
    test "a handful of stray characters across many pages is still a scan" do
      assert TextExtraction.image_only?("Seite 1\fSeite 2\fSeite 3", 3)
    end

    test "judges per page, not in total" do
      one_full_page = String.duplicate("a", 400)

      refute TextExtraction.image_only?(one_full_page, 1)
      # The same text spread over ten pages averages 40 characters each, which
      # is what a mostly-scanned document looks like.
      assert TextExtraction.image_only?(one_full_page, 10)
    end

    test "treats a missing page count as one page" do
      refute TextExtraction.image_only?(String.duplicate("a", 100), nil)
      assert TextExtraction.image_only?("kurz", nil)
    end

    test "whitespace does not count as content" do
      assert TextExtraction.image_only?(String.duplicate(" \n\t", 200), 1)
    end
  end

  describe "extract/1 on a text PDF" do
    @describetag :pdf

    test "reads the text and reports where it came from" do
      if TextExtraction.pdftotext_available?() do
        assert {:ok, text, source} = TextExtraction.extract(@pdf_fixture)
        assert source == "pdf_text"
        assert text =~ "Fachinformatikerin"
        assert text =~ "IHK Hamburg"
      end
    end

    test "the reported source is one the schema accepts" do
      if TextExtraction.pdftotext_available?() do
        {:ok, _text, source} = TextExtraction.extract(@pdf_fixture)
        assert source in JobReference.body_sources()
      end
    end

    # `pdftotext -layout` pads with runs of blank lines and trailing spaces.
    # The stored body should not carry them into the prompt.
    test "normalises the whitespace it returns" do
      if TextExtraction.pdftotext_available?() do
        {:ok, text, _source} = TextExtraction.extract(@pdf_fixture)

        refute text =~ ~r/\n{3,}/
        refute text =~ ~r/[ \t]+\n/
        assert text == String.trim(text)
      end
    end
  end

  # The bug this feature shipped with, and the reason both of these are
  # asserted rather than left to a comment.
  describe "a reader that does not answer" do
    setup do
      original = Application.fetch_env(:vutuv, :ollama_url)
      # A port nothing listens on: the real transport path, not a stub.
      Application.put_env(:vutuv, :ollama_url, "http://127.0.0.1:1")
      Application.put_env(:vutuv, :reference_ocr, :vision)

      on_exit(fn ->
        case original do
          {:ok, was} -> Application.put_env(:vutuv, :ollama_url, was)
          :error -> Application.delete_env(:vutuv, :ollama_url)
        end

        Application.delete_env(:vutuv, :reference_ocr)
      end)
    end

    # `:empty` is a statement about the member's document ("it contains no
    # text"). When the model never answered, that statement is false and sends
    # them looking for a fault in their own file.
    test "reports itself unavailable, not the document empty" do
      path = Path.join(System.tmp_dir!(), "ocr_#{System.unique_integer([:positive])}.png")
      File.write!(path, "not really a png, never decoded — the call fails first")

      try do
        assert {:error, :unavailable} = TextExtraction.extract(path)
      after
        File.rm(path)
      end
    end
  end

  describe "capability detection" do
    test "answers without raising on any host" do
      assert is_boolean(TextExtraction.pdftotext_available?())
      assert is_boolean(TextExtraction.pdftoppm_available?())
      assert is_boolean(TextExtraction.tesseract_available?())
      assert is_boolean(TextExtraction.ocr_available?())
    end

    test "a corrupt file is reported, not raised" do
      path = Path.join(System.tmp_dir!(), "broken_#{System.unique_integer([:positive])}.pdf")
      File.write!(path, "this is not a PDF")

      try do
        assert {:error, reason} = TextExtraction.extract(path)
        assert reason in [:unreadable, :unsupported, :empty, :unavailable]
      after
        File.rm(path)
      end
    end
  end
end
