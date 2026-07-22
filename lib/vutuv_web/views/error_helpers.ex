defmodule VutuvWeb.ErrorHelpers do
  @moduledoc """
  Conveniences for translating and building error messages.
  """

  use PhoenixHTMLHelpers
  use Gettext, backend: VutuvWeb.Gettext

  @doc """
  Generates tag for inlined form input errors.
  """
  def error_tag(form, field) do
    if error = form.errors[field] do
      content_tag(:span, translate_error(error), class: "editform__error")
    end
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # Because error messages were defined within Ecto, we must
    # call the Gettext module passing our Gettext backend. We
    # also use the "errors" domain as translations are placed
    # in the errors.po file. On your own code and templates,
    # this could be written simply as:
    #
    #     dngettext "errors", "1 file", "%{count} files", count
    #
    if count = opts[:count] do
      Gettext.dngettext(VutuvWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(VutuvWeb.Gettext, "errors", msg, opts)
    end
  end

  def translate_error(msg) do
    Gettext.dgettext(VutuvWeb.Gettext, "errors", msg)
  end

  # Extraction anchors: custom `add_error/3` messages live as literal strings
  # inside schema modules, where `mix gettext.extract` cannot see them.
  # Declaring them here with `dgettext_noop` puts the msgids into errors.pot,
  # so `translate_error/1` finds a German msgstr at render time. Keep each
  # string byte-identical to its `add_error` twin.
  @doc false
  def __error_message_extraction_anchors__ do
    [
      # Vutuv.Profiles.Qualification, the proof-document upload (consent gate).
      dgettext_noop(
        "errors",
        "Please confirm that the file may be shown publicly. Without your consent nothing is uploaded."
      ),
      dgettext_noop("errors", "is larger than 10 MB. Please upload a smaller file."),
      dgettext_noop(
        "errors",
        "PDF uploads are not available on this installation. Please upload an image instead."
      ),
      dgettext_noop("errors", "could not be read. Please upload a PDF, JPG, PNG or WebP file.")
    ]
  end
end
