defmodule Vutuv.IdentitySeamDirectionTest do
  @moduledoc """
  `Vutuv.Identity` is the seam that answers "what is this identity called".
  `VutuvWeb.UserHelpers.full_name/1` is a one-line delegate to it — the web
  layer's own name for the same question.

  Seven call sites inside `lib/vutuv/` reached the seam *through* that delegate,
  which made the context layer compile-depend on `lib/vutuv_web/views/` — the
  wrong direction, and the one that would block ever splitting the two. The
  Mastodon presenter's whole dependency on the web layer was this and nothing
  else.

  The delegate stays for the templates that call it; what this pins is the
  direction of the arrow.
  """
  use ExUnit.Case, async: true

  test "no context module asks the web layer who somebody is" do
    offenders =
      for path <- Path.wildcard("lib/vutuv/**/*.ex"),
          {line, n} <- Enum.with_index(String.split(File.read!(path), "\n"), 1),
          line =~ ~r/UserHelpers\.full_name/,
          do: "#{path}:#{n}: #{String.trim(line)}"

    assert offenders == [],
           "call Vutuv.Identity.display_name/1 directly — the context layer owns " <>
             "this question and the delegate points back at it:\n" <> Enum.join(offenders, "\n")
  end

  test "the delegate still answers the same thing, so the templates keep working" do
    user = %Vutuv.Accounts.User{first_name: "Ada", last_name: "Lovelace"}

    assert VutuvWeb.UserHelpers.full_name(user) == Vutuv.Identity.display_name(user)
  end
end
