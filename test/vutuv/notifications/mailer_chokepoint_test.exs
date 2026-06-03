defmodule Vutuv.Notifications.MailerChokepointTest do
  @moduledoc """
  Regression guard for issue #763: all outbound mail must flow through the one
  `Vutuv.Notifications.Emailer.deliver/1` chokepoint, which is the only place
  that may call `Vutuv.Mailer.deliver/1` or build a Swoosh email. This keeps the
  auto-generated robot headers (and the `From`) impossible to forget.
  """
  use ExUnit.Case, async: true

  @emailer_path "lib/vutuv/notifications/emailer.ex"
  @mailer_path "lib/vutuv/mailer.ex"

  test "only the Emailer module calls Vutuv.Mailer.deliver/1" do
    offenders =
      lib_files()
      |> Enum.reject(&(&1 == @emailer_path))
      |> Enum.filter(&(File.read!(&1) =~ "Vutuv.Mailer.deliver("))

    assert offenders == [],
           "Vutuv.Mailer.deliver/1 must only be called from #{@emailer_path}. " <>
             "Send mail through Vutuv.Notifications.Emailer.deliver/1 instead. " <>
             "Offending files: #{Enum.join(offenders, ", ")}"
  end

  test "only the Emailer module builds Swoosh emails" do
    offenders =
      lib_files()
      |> Enum.reject(&(&1 in [@emailer_path, @mailer_path]))
      |> Enum.filter(fn path ->
        contents = File.read!(path)
        contents =~ "import Swoosh.Email" or contents =~ "Swoosh.Email.new("
      end)

    assert offenders == [],
           "Swoosh emails must only be built in #{@emailer_path}. " <>
             "Use Vutuv.Notifications.Emailer.base_email/0 instead. " <>
             "Offending files: #{Enum.join(offenders, ", ")}"
  end

  defp lib_files, do: Path.wildcard("lib/**/*.ex")
end
