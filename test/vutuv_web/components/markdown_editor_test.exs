defmodule VutuvWeb.MarkdownEditorTest do
  @moduledoc """
  The shared Milkdown Markdown editor component (VutuvWeb.UI.markdown_editor/1),
  used by both the post composer and the message composer. These assert the
  server-rendered scaffold the `MarkdownEditor` JS hook enhances: the hidden
  textarea is still a real form field (so submit + the no-JS fallback keep
  working), the hook mount point is present, and every Markdown feature the
  server actually renders has a toolbar command — nothing more (no task lists).
  """
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  defp editor(overrides \\ %{}) do
    assigns =
      Map.merge(
        %{
          id: "ed",
          name: "post[body]",
          value: "hello **world**",
          label: "Body",
          placeholder: "Write something…"
        },
        overrides
      )

    render_component(&VutuvWeb.UI.markdown_editor/1, assigns)
  end

  test "the hidden textarea stays the form field and the no-JS fallback" do
    html = editor()

    # A real <textarea name=…> carrying the value: it submits with JS off and is
    # what Milkdown mirrors into, so the server pipeline is unchanged.
    assert html =~ ~s(<textarea)
    assert html =~ ~s(name="post[body]")
    assert html =~ "data-mde-source"
    assert html =~ "hello **world**"
    # Not a single-line input.
    refute html =~ ~s(<input name="post[body]")
  end

  test "the hook mount point carries the seed markdown and placeholder" do
    html = editor()

    assert html =~ ~s(id="ed")
    assert html =~ ~s(phx-hook="MarkdownEditor")
    # data-mde-value re-seeds the editor on server-driven changes (image insert,
    # post-save reset, message clear).
    assert html =~ ~s(data-mde-value="hello **world**")
    assert html =~ ~s(data-mde-placeholder="Write something…")
    assert html =~ "data-mde-mount"
  end

  test "every rendered Markdown feature has a toolbar command" do
    html = editor()

    for cmd <- ~w(strong em strike code link h1 h2 h3 blockquote code_block
                  bullet_list ordered_list table hr) do
      assert html =~ ~s(data-mde-cmd="#{cmd}"), "missing toolbar command: #{cmd}"
    end
  end

  test "task lists are intentionally NOT offered (server renders them as text)" do
    html = editor()
    refute html =~ ~s(data-mde-cmd="task)
    refute html =~ "checkbox"
  end

  test "power users get a WYSIWYG/source toggle and a full-screen control" do
    html = editor()
    assert html =~ ~s(data-mde-cmd="mode")
    assert html =~ ~s(data-mde-cmd="fullscreen")
  end

  test "submit_on and compact are passed through for the message composer" do
    html = editor(%{name: "message[body]", submit_on: "cmd-enter", compact: true, rows: 2})

    assert html =~ ~s(name="message[body]")
    assert html =~ ~s(data-mde-submit="cmd-enter")
    assert html =~ "mde--compact"
    assert html =~ ~s(rows="2")
  end
end
