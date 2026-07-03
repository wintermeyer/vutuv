defmodule Vutuv.Profiles.SocialMediaAccountTest do
  use Vutuv.DataCase

  alias Vutuv.Profiles.SocialMediaAccount

  defp value_for(params) do
    SocialMediaAccount.changeset(%SocialMediaAccount{}, params)
    |> Ecto.Changeset.apply_changes()
    |> Map.get(:value)
  end

  describe "changeset/2 provider validation" do
    test "accepts a supported provider" do
      changeset =
        SocialMediaAccount.changeset(%SocialMediaAccount{}, %{
          provider: "Facebook",
          value: "vutuv"
        })

      assert changeset.valid?
    end

    test "accepts Mastodon" do
      changeset =
        SocialMediaAccount.changeset(%SocialMediaAccount{}, %{
          provider: "Mastodon",
          value: "@Gargron@mastodon.social"
        })

      assert changeset.valid?
    end

    test "accepts Bluesky" do
      changeset =
        SocialMediaAccount.changeset(%SocialMediaAccount{}, %{
          provider: "Bluesky",
          value: "gargron.bsky.social"
        })

      assert changeset.valid?
    end

    test "rejects Google+ as a provider" do
      changeset =
        SocialMediaAccount.changeset(%SocialMediaAccount{}, %{provider: "Google+", value: "vutuv"})

      refute changeset.valid?
      assert changeset.errors[:provider]
    end

    test "rejects a Mastodon handle without an instance" do
      changeset =
        SocialMediaAccount.changeset(%SocialMediaAccount{}, %{
          provider: "Mastodon",
          value: "Gargron"
        })

      refute changeset.valid?
      assert changeset.errors[:value]
    end

    test "rejects a Mastodon-style handle for Bluesky" do
      changeset =
        SocialMediaAccount.changeset(%SocialMediaAccount{}, %{
          provider: "Bluesky",
          value: "alice@example.social"
        })

      refute changeset.valid?
      assert changeset.errors[:value]
    end
  end

  describe "Bluesky value parsing" do
    test "stores the handle lowercased, stripping a leading @" do
      assert value_for(%{provider: "Bluesky", value: "@Alice.Bsky.Social"}) ==
               "alice.bsky.social"
    end

    test "a bare name without a dot gets the default .bsky.social namespace" do
      assert value_for(%{provider: "Bluesky", value: "alice"}) == "alice.bsky.social"
    end

    test "a custom-domain handle is stored as typed" do
      assert value_for(%{provider: "Bluesky", value: "alice.example.com"}) ==
               "alice.example.com"
    end

    test "extracts the handle from a pasted profile URL" do
      assert value_for(%{
               provider: "Bluesky",
               value: "https://bsky.app/profile/alice.bsky.social"
             }) ==
               "alice.bsky.social"
    end
  end

  describe "Mastodon value parsing" do
    test "stores the bare user@instance handle, stripping a leading @" do
      assert value_for(%{provider: "Mastodon", value: "@Gargron@mastodon.social"}) ==
               "Gargron@mastodon.social"
    end

    test "accepts the bare user@instance form" do
      assert value_for(%{provider: "Mastodon", value: "Gargron@mastodon.social"}) ==
               "Gargron@mastodon.social"
    end

    test "extracts the handle from a pasted profile URL" do
      assert value_for(%{provider: "Mastodon", value: "https://mastodon.social/@Gargron"}) ==
               "Gargron@mastodon.social"
    end
  end

  describe "url/1" do
    test "builds the federated profile URL for Mastodon" do
      account = %SocialMediaAccount{provider: "Mastodon", value: "Gargron@mastodon.social"}
      assert SocialMediaAccount.url(account) == "https://mastodon.social/@Gargron"
    end

    test "builds the profile URL for Bluesky" do
      account = %SocialMediaAccount{provider: "Bluesky", value: "gargron.bsky.social"}
      assert SocialMediaAccount.url(account) == "https://bsky.app/profile/gargron.bsky.social"
    end
  end

  describe "social_media_link/1" do
    test "builds a link for a supported provider" do
      account = %SocialMediaAccount{provider: "Facebook", value: "vutuv"}
      assert {:safe, _} = SocialMediaAccount.social_media_link(account)
    end

    test "builds a link for Mastodon" do
      account = %SocialMediaAccount{provider: "Mastodon", value: "Gargron@mastodon.social"}
      assert {:safe, _} = SocialMediaAccount.social_media_link(account)
    end

    test "builds a link for Bluesky" do
      account = %SocialMediaAccount{provider: "Bluesky", value: "gargron.bsky.social"}
      assert {:safe, _} = SocialMediaAccount.social_media_link(account)
    end

    test "returns an empty string for Google+" do
      account = %SocialMediaAccount{provider: "Google+", value: "vutuv"}
      assert SocialMediaAccount.social_media_link(account) == ""
    end
  end
end
