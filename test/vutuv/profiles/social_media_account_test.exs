defmodule Vutuv.Profiles.SocialMediaAccountTest do
  use Vutuv.DataCase

  alias Vutuv.Profiles.SocialMediaAccount

  describe "changeset/2 provider validation" do
    test "accepts a supported provider" do
      changeset = SocialMediaAccount.changeset(%SocialMediaAccount{}, %{provider: "Facebook", value: "vutuv"})
      assert changeset.valid?
    end

    test "rejects Google+ as a provider" do
      changeset = SocialMediaAccount.changeset(%SocialMediaAccount{}, %{provider: "Google+", value: "vutuv"})
      refute changeset.valid?
      assert changeset.errors[:provider]
    end
  end

  describe "social_media_link/1" do
    test "builds a link for a supported provider" do
      account = %SocialMediaAccount{provider: "Facebook", value: "vutuv"}
      assert {:safe, _} = SocialMediaAccount.social_media_link(account)
    end

    test "returns an empty string for Google+" do
      account = %SocialMediaAccount{provider: "Google+", value: "vutuv"}
      assert SocialMediaAccount.social_media_link(account) == ""
    end
  end
end
