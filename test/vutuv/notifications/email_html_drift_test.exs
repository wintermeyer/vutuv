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
end
