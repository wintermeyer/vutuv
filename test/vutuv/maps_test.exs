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

  describe "address_link/2" do
    test "a logged-out viewer gets Google Maps" do
      link = Maps.address_link(address(), nil)

      assert link.service == :google
      assert link.label == "Google Maps"
      assert link.url =~ "https://www.google.com/maps/search/"
    end

    test "a member gets the default they chose" do
      user = %User{map_apple?: true, default_map_service: "apple"}

      assert %{service: :apple, url: "https://maps.apple.com/" <> _} =
               Maps.address_link(address(), user)
    end

    test "disabling every service leaves the address unlinked" do
      user = %User{map_google?: false, map_openstreetmap?: false, map_apple?: false}
      assert Maps.address_link(address(), user) == nil
    end

    test "an address without a city gets no link, whatever the viewer enabled" do
      country_only = struct(Address, %{country: "Germany", zip_code: "56068"})

      assert Maps.address_link(country_only, nil) == nil
    end

    test "the geocoding query carries the address" do
      link = Maps.address_link(address(), nil)

      assert link.url =~ "Koblenz"
      assert link.url =~ "Germany"
    end
  end

  describe "choice_attrs/2" do
    test "\"none\" turns every service off" do
      assert Maps.choice_attrs(%User{}, "none") == %{
               "map_google?" => false,
               "map_openstreetmap?" => false,
               "map_apple?" => false
             }
    end

    # Switched on explicitly even where the flag still inherits (nil): an
    # admin who later turns that service off site-wide must not move a member
    # who picked it onto another one.
    test "a service becomes the default and is switched on for this member" do
      assert Maps.choice_attrs(%User{}, "openstreetmap") == %{
               "default_map_service" => "openstreetmap",
               "map_openstreetmap?" => true
             }
    end

    test "an unknown value is passed on for the changeset to reject" do
      assert Maps.choice_attrs(%User{}, "bing") == %{"default_map_service" => "bing"}
    end
  end
end
