defmodule Vutuv.MapsTest do
  use ExUnit.Case, async: true

  alias Vutuv.Accounts.User
  alias Vutuv.Maps
  alias Vutuv.Profiles.Address

  defp address do
    struct(Address, %{
      country: "Germany",
      line_1: "Johannes-Müller-Str. 10",
      zip_code: "56068",
      city: "Koblenz"
    })
  end

  describe "the canonical service list" do
    test "is Google, OpenStreetMap, Apple in display order" do
      assert Maps.services() == [:google, :openstreetmap, :apple]
      assert Maps.service_strings() == ["google", "openstreetmap", "apple"]
    end

    test "valid_service?/1 only accepts the known string forms" do
      assert Maps.valid_service?("google")
      assert Maps.valid_service?("apple")
      refute Maps.valid_service?("bing")
      refute Maps.valid_service?(:google)
      refute Maps.valid_service?(nil)
    end

    test "label/1 names each service" do
      assert Maps.label(:google) == "Google Maps"
      assert Maps.label(:openstreetmap) == "OpenStreetMap"
      assert Maps.label(:apple) == "Apple Maps"
    end
  end

  describe "enabled_services/1" do
    test "a logged-out viewer (nil) gets all three" do
      assert Maps.enabled_services(nil) == [:google, :openstreetmap, :apple]
    end

    test "a member with every flag on gets all three, in canonical order" do
      user = %User{map_google?: true, map_openstreetmap?: true, map_apple?: true}
      assert Maps.enabled_services(user) == [:google, :openstreetmap, :apple]
    end

    test "a disabled service drops out" do
      user = %User{map_google?: false, map_openstreetmap?: true, map_apple?: false}
      assert Maps.enabled_services(user) == [:openstreetmap]
    end

    test "legacy nil flags read as on" do
      user = %User{map_google?: nil, map_openstreetmap?: nil, map_apple?: nil}
      assert Maps.enabled_services(user) == [:google, :openstreetmap, :apple]
    end
  end

  describe "default_service/1" do
    test "a logged-out viewer defaults to Google" do
      assert Maps.default_service(nil) == :google
    end

    test "honours the member's stored default when it is enabled" do
      user = %User{map_apple?: true, default_map_service: "apple"}
      assert Maps.default_service(user) == :apple
    end

    test "falls back to the first enabled service when the default is disabled" do
      # Default points at Google, but Google is off: the first enabled wins.
      user = %User{
        map_google?: false,
        map_openstreetmap?: true,
        map_apple?: true,
        default_map_service: "google"
      }

      assert Maps.default_service(user) == :openstreetmap
    end

    test "is nil when every service is disabled" do
      user = %User{map_google?: false, map_openstreetmap?: false, map_apple?: false}
      assert Maps.default_service(user) == nil
    end
  end

  describe "address_links/2" do
    test "a logged-out viewer sees Google primary, the rest as alternatives" do
      %{primary: primary, alternatives: alts} = Maps.address_links(address(), nil)

      assert primary.service == :google
      assert primary.label == "Google Maps"
      assert primary.url =~ "https://www.google.com/maps/search/"
      assert Enum.map(alts, & &1.service) == [:openstreetmap, :apple]
    end

    test "the member's default becomes the primary; alternatives keep canonical order" do
      user = %User{map_apple?: true, default_map_service: "apple"}

      %{primary: primary, alternatives: alts} = Maps.address_links(address(), user)

      assert primary.service == :apple
      assert primary.url =~ "https://maps.apple.com/"
      assert Enum.map(alts, & &1.service) == [:google, :openstreetmap]
    end

    test "a single enabled service renders just the primary, no alternatives" do
      user = %User{
        map_google?: false,
        map_openstreetmap?: true,
        map_apple?: false,
        default_map_service: "openstreetmap"
      }

      assert %{primary: %{service: :openstreetmap}, alternatives: []} =
               Maps.address_links(address(), user)
    end

    test "disabling every service hides the map entirely" do
      user = %User{map_google?: false, map_openstreetmap?: false, map_apple?: false}
      assert %{primary: nil, alternatives: []} = Maps.address_links(address(), user)
    end

    test "every link's geocoding query still carries the address" do
      %{primary: primary, alternatives: alts} = Maps.address_links(address(), nil)

      for link <- [primary | alts] do
        assert link.url =~ "Koblenz"
        assert link.url =~ "Germany"
      end
    end
  end
end
