defmodule VutuvWeb.ErrorHelpers do
  @moduledoc """
  Conveniences for translating and building error messages.
  """

  use PhoenixHTMLHelpers
  use Gettext, backend: VutuvWeb.Gettext

  alias Phoenix.HTML.Form

  @doc """
  Generates tag for inlined form input errors.

  The span carries a stable `id` derived from the input's own id
  (`url_value_error`), which is what `err_attrs/2` points `aria-describedby`
  at, so a screen reader reads the reason together with the field instead of
  leaving the message orphaned two nodes away.
  """
  def error_tag(form, field) do
    if error = form.errors[field] do
      content_tag(:span, translate_error(error),
        class: "editform__error",
        id: error_id(form, field)
      )
    end
  end

  @doc """
  The accessible state a failed field owes its user, as input options.

  Returns `[]` for a clean field, and for a failed one the pair that makes the
  red border mean something to a person who cannot see it: `aria-invalid`
  (this control is wrong) and `aria-describedby` pointing at the `error_tag/2`
  span right below it (this is why). Colour alone would leave the error
  invisible to a screen-reader or colour-blind user — WCAG 1.4.1 / 3.3.1.

  Pass it as the input's options, appending to any the field already has:

      <%= text_input f, :value, err_attrs(f, :value) %>
      <%= text_input f, :value, [placeholder: "…"] ++ err_attrs(f, :value) %>
  """
  def err_attrs(form, field) do
    if form.errors[field] do
      ["aria-invalid": "true"] ++
        case error_id(form, field) do
          nil -> []
          id -> ["aria-describedby": id]
        end
    else
      []
    end
  end

  # `error_tag/2` is called with a `%Phoenix.HTML.Form{}` on the classic form
  # pages and with a bare `%Ecto.Changeset{}` in a few LiveViews (TagNewLive),
  # which has `.errors` but no input ids to derive one from. Only the form case
  # can name an id, so the changeset case renders the message without one — it
  # still reads, it just cannot be pointed at by `aria-describedby`.
  defp error_id(%Form{} = form, field), do: "#{Form.input_id(form, field)}_error"
  defp error_id(_other, _field), do: nil

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
      dgettext_noop("errors", "could not be read. Please upload a PDF, JPG, PNG or WebP file."),
      # Vutuv.Tags.Tag / Vutuv.Accounts.User, the "this field is not a
      # billboard" rule (Vutuv.WebAddress).
      dgettext_noop("errors", "must not be a web or email address"),
      dgettext_noop(
        "errors",
        "can't be only a link. Please describe yourself in a few words."
      ),
      dgettext_noop(
        "errors",
        "\"%{tag}\" is a web address, not a tag. Please describe yourself with words."
      ),
      # Vutuv.Tags.Tag, a name of punctuation only.
      dgettext_noop("errors", "must not be only punctuation"),
      dgettext_noop("errors", "\"%{tag}\" is only punctuation, not a tag."),
      # Vutuv.Accounts.User, the Fediverse aliases (issue #986, alsoKnownAs).
      dgettext_noop("errors", "Please list at most %{max} accounts."),
      dgettext_noop("errors", "\"%{uri}\" is not a valid https account address.")
    ]
  end
end
