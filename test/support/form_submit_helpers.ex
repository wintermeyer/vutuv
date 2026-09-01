defmodule Vutuv.FormSubmitHelpers do
  @moduledoc """
  The one check for "can a browser actually submit this form?" (issue #1896).

  HTML only performs **implicit submission** — Return in a field submitting the
  form — when the form either has a submit control, or holds exactly one field
  that blocks it. Grow a second text field on a form with no button and Return
  goes dead, with no error anywhere: the member presses Return, nothing
  happens, and every test stays green. That is exactly how the feed's "Wörter
  ausblenden" card lost its save (issue #1888).

  It lived as a private helper inside `filter_band_test.exs`, which watched the
  feed and nothing else — one page of the roughly thirty that carry a
  submitting form. It is here so any test holding rendered HTML can ask.

  **It cannot be a source scan**, and that is what makes it worth having: the
  offending second field usually arrives from a caller's slot, so the component
  reads as a one-field form in its own source, and `<.form_actions>` emits a
  submit button a scanner would not see either. Only the rendered page knows.

  ## Using it

      import Vutuv.FormSubmitHelpers

      {:ok, view, _html} = live(conn, ~p"/feed")
      assert_forms_submittable(render(view), "/feed")

  Pass `min_forms:` where a page is expected to carry some, so the sweep cannot
  pass by finding nothing — a page that renders no forms at all otherwise reads
  as a page whose forms are all fine.
  """

  import ExUnit.Assertions

  # The `<input>` types that participate in implicit submission. A checkbox, a
  # radio or a file input does not block it, so a form full of those and one
  # text field is still submittable by Return.
  @blocking_types ~w(text search url tel email password date month week time datetime-local number)

  @doc """
  Asserts every `phx-submit` form in `html` can be submitted from a keyboard.

  `where` names the page in the failure message — the whole value of this
  check is that it fires far from the code that broke it, so it has to say
  where it was looking.
  """
  def assert_forms_submittable(html, where, opts \\ []) do
    forms =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("form[phx-submit]")
      |> Enum.to_list()

    case Keyword.get(opts, :min_forms) do
      nil ->
        :ok

      min ->
        assert length(forms) >= min,
               "#{where}: expected at least #{min} form(s) with phx-submit, found " <>
                 "#{length(forms)} — the sweep would have passed vacuously"
    end

    for form <- forms do
      assert submittable?(form),
             """
             #{where}: a form cannot be submitted by pressing Return.

               phx-submit: #{inspect(attr(form, "phx-submit"))}
               fields that block implicit submission: #{blocking_fields(form)}
               submit control: no
               phx-change repeating the submit event: no

             HTML gives a form implicit submission only with a submit control,
             or with at most one field that blocks it. Add a submit button —
             `class="sr-only"` if the page should not draw one.
             """
    end

    :ok
  end

  @doc "Whether one parsed form can be submitted from a keyboard."
  def submittable?(form) do
    blocking_fields(form) < 2 or submit_control?(form) or change_repeats_submit?(form)
  end

  # Fewer than two blocking fields and the browser submits on Return by itself.
  def blocking_fields(form) do
    form
    |> LazyHTML.query("input")
    |> Enum.count(fn input ->
      case LazyHTML.attribute(input, "type") do
        [] -> true
        [type] -> String.downcase(type) in @blocking_types
        _ -> false
      end
    end)
  end

  # A `<button>` inside a form submits it unless it says otherwise, so the
  # absent type counts as a submit control and only "button"/"reset" do not.
  def submit_control?(form) do
    has_button? =
      form
      |> LazyHTML.query("button")
      |> Enum.any?(fn button ->
        case LazyHTML.attribute(button, "type") do
          [] -> true
          [type] -> String.downcase(type) == "submit"
          _ -> false
        end
      end)

    has_button? or Enum.any?(LazyHTML.query(form, ~s(input[type="submit"], input[type="image"])))
  end

  # The one honest exemption: a form whose `phx-change` names the same event as
  # its `phx-submit` loses nothing when Return is dead, because typing already
  # did what Return would have. The admin activity log and the tag timeline
  # filter that way. Read off the SAME form, never off the page — an exemption
  # found elsewhere in the document is not this form's.
  def change_repeats_submit?(form) do
    submit = attr(form, "phx-submit")
    submit != nil and attr(form, "phx-change") == submit
  end

  defp attr(form, name) do
    case LazyHTML.attribute(form, name) do
      [value] -> value
      _ -> nil
    end
  end
end
