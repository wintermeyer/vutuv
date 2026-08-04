defmodule Vutuv.InvitationsPrefillTest do
  @moduledoc """
  `Vutuv.Invitations.prefill_from_params/1` — what an invitation link puts into
  the sign-up form.

  The reason this file exists is the one thing a rename cannot control: an
  invitation link sits in somebody's inbox for months, so the slot that carries
  a salutation today went out carrying a gender word yesterday, in the compact
  `i=` token and in the spelled-out params alike. Every one of those links has to
  keep working, and "keep working" means the salutation the sender chose still
  arrives — degrading to a blank form would silently undo their choice on every
  invitation already sent.
  """
  use ExUnit.Case, async: true

  alias Vutuv.Invitations
  alias Vutuv.Invitations.PrefillToken

  describe "current links" do
    test "a token round-trips the salutation" do
      token = PrefillToken.encode(%{"salutation" => "ms", "first_name" => "Jane"})

      assert %{"salutation" => "ms", "first_name" => "Jane"} =
               Invitations.prefill_from_params(%{PrefillToken.param() => token})
    end

    test "spelled-out params carry the salutation" do
      assert %{"salutation" => "mr", "first_name" => "Max"} =
               Invitations.prefill_from_params(%{"salutation" => "mr", "first_name" => "Max"})
    end

    test "an unknown salutation is dropped rather than passed on" do
      # The sign-up form would refuse it anyway; dropping it here keeps the
      # prefill map honest for every other reader.
      prefill = Invitations.prefill_from_params(%{"salutation" => "captain", "email" => "a@b.de"})

      refute Map.has_key?(prefill, "salutation")
      assert prefill["email"] == "a@b.de"
    end
  end

  describe "links sent before the field became a salutation" do
    test "a spelled-out gender becomes the matching salutation" do
      assert %{"salutation" => "ms"} =
               Invitations.prefill_from_params(%{"gender" => "female", "first_name" => "Jane"})

      assert %{"salutation" => "mr"} =
               Invitations.prefill_from_params(%{"gender" => "male", "first_name" => "Max"})
    end

    test "an old token's first slot is read as a gender word too" do
      # The token is positional and its layout did not change, so an old link
      # decodes with "female" sitting in what is now the salutation slot.
      token = PrefillToken.encode(%{"salutation" => "female", "first_name" => "Jane"})

      assert %{"salutation" => "ms", "first_name" => "Jane"} =
               Invitations.prefill_from_params(%{PrefillToken.param() => token})
    end

    test "the third gender carried no salutation and gets none" do
      prefill = Invitations.prefill_from_params(%{"gender" => "other", "first_name" => "Alex"})

      refute Map.has_key?(prefill, "salutation")
      assert prefill["first_name"] == "Alex"
    end

    test "the legacy key never survives into the prefill" do
      prefill = Invitations.prefill_from_params(%{"gender" => "female"})

      refute Map.has_key?(prefill, "gender")
    end
  end

  test "a bare visit prefills nothing" do
    assert Invitations.prefill_from_params(%{}) == %{}
  end
end
