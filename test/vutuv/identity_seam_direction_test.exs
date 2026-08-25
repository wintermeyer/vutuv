defmodule Vutuv.IdentitySeamDirectionTest do
  @moduledoc """
  `Vutuv.Identity` is the seam that answers "what is this identity called".
  `VutuvWeb.UserHelpers.full_name/1` is a one-line delegate to it — the web
  layer's own name for the same question.

  Seven call sites inside `lib/vutuv/` reached the seam *through* that delegate,
  which made the context layer compile-depend on `lib/vutuv_web/views/` — the
  wrong direction, and the one that would block ever splitting the two.

  The delegate stays for the templates that call it; what this pins is the
  direction of the arrow for **this one question**. It deliberately does not ban
  every `UserHelpers` call from `lib/vutuv/`: `email_greeting/1` and
  `name_for_email_to_field/1` survive in the emailer and the newsletter builder,
  and those really are presentation — how a salutation reads, what goes into a
  `To:` display name — so the web layer is where they belong. Naming a question
  is what the context layer owns; wording it is not.

  Calibrated against `origin/main`, where it names seven offenders.
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
end
