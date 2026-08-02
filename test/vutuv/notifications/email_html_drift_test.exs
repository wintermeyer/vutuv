defmodule Vutuv.Notifications.EmailHtmlDriftTest do
  @moduledoc """
  Every email is sent as multipart: a `text/plain` body (the `*.text.eex`
  templates in `lib/vutuv_web/templates/email/`) and an `text/html` alternative
  (the `*.html.heex` bodies in `lib/vutuv_web/templates/email_body/`, rendered
  through `VutuvWeb.EmailComponents`). The two must stay paired: an email added
  with only one of the two formats is the drift this test fails the build on.
  """
  use ExUnit.Case, async: true

  @text_dir "lib/vutuv_web/templates/email"
  @html_dir "lib/vutuv_web/templates/email_body"

  # The per-locale body templates, by base name (no partials, which start with "_").
  defp text_bases do
    Path.wildcard(Path.join(@text_dir, "*.text.eex"))
    |> Enum.map(&Path.basename(&1, ".text.eex"))
    |> Enum.reject(&String.starts_with?(&1, "_"))
    |> Enum.sort()
  end

  defp html_bases do
    Path.wildcard(Path.join(@html_dir, "*.html.heex"))
    |> Enum.map(&Path.basename(&1, ".html.heex"))
    |> Enum.sort()
  end

  test "every text email body has a matching HTML body" do
    missing = text_bases() -- html_bases()

    assert missing == [],
           "These emails have a #{@text_dir}/*.text.eex but no #{@html_dir}/*.html.heex " <>
             "(add the HTML alternative): #{Enum.join(missing, ", ")}"
  end

  test "every HTML email body has a matching text body" do
    missing = html_bases() -- text_bases()

    assert missing == [],
           "These emails have a #{@html_dir}/*.html.heex but no #{@text_dir}/*.text.eex: " <>
             Enum.join(missing, ", ")
  end

  test "every text template is compiled into a VutuvWeb.EmailText function" do
    # `EmailText` builds one function per template from a compile-time wildcard,
    # and each matched file becomes an `@external_resource` — so *editing* a
    # template recompiles it but *adding* one would not, since the new file is
    # not yet tracked and nothing else in that module changed. Where the build
    # directory survives (an incremental local build, and CI, which caches
    # `_build`), the new template silently never compiles.
    #
    # That shipped a red CI on a green local `mix precommit` (issue #1086: the
    # username-change PIN mail raised `function
    # VutuvWeb.EmailText.username_change_email_en/1 is undefined`). `EmailText`
    # now defines `__mix_recompile__?/0` so Mix rebuilds it whenever the *set*
    # of templates changes; this asserts the outcome rather than the mechanism.
    # `function_exported?/3` answers **false for every function of a module that
    # is not loaded**, and module loading is lazy: whether anything has touched
    # `EmailText` by the time this async test runs depends on the seed and on
    # `max_cases`. Without this line the test therefore fails at random with
    # *all* templates listed as missing — which turned main red right after
    # v7.226.0 merged, on a commit whose own PR run was green and which passed
    # on re-run. Note the shape of that lie: real drift is one new template, so
    # a list naming every one of them is this bug, not a missing function.
    Code.ensure_loaded!(VutuvWeb.EmailText)

    missing =
      for base <- text_bases(),
          not function_exported?(VutuvWeb.EmailText, String.to_atom(base), 1),
          do: base

    assert missing == [],
           "These templates exist but have no VutuvWeb.EmailText function: " <>
             Enum.join(missing, ", ") <>
             ". Run `mix compile --force` — and if that fixes it, the module's " <>
             "__mix_recompile__?/0 is not doing its job."
  end
end
